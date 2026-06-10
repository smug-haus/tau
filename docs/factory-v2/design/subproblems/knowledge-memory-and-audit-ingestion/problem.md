---
template_version: 1
template_name: problem
node_kind: leaf
mode: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Knowledge / memory — audit findings must mechanically gate the next PR that touches their surface

## Statement

Writing down an audit finding (in `docs/problems/`,
`docs/problems-archive-v1-modules/`, an ADR, or a SPEC §3 invariant)
must *cause* the factory to consider it on the next PR that touches
the relevant surface; today, writing a finding is a no-op until a
human re-reads it. v1's symptom: the prior module audit's
recommendations have not been ingested — zero of seven flagged
`rescue` sites moved, and new `rescue` sites accumulated *since the
audit was written* (root #10). The problem is solved when an audit
finding's lifecycle is "authored → registered as a check input →
enforced on every subsequent PR touching the named surface, until
remediated or explicitly waived with an expiry."

## Context

- Root §Hypothesis #10 — prior audit recommendations not ingested;
  rescue sites accumulated after the audit was written.
- Root §Acceptance F (Backward integration) — "The factory ingests
  the audit findings (`docs/problems/` + `docs/problems-archive-v1-
  modules/`) as input, not as advice. The corrective-actions
  catalogue (`docs/factory-v2/corrective-actions.md`) is the
  factory's initial backlog, processed by the same mechanisms it
  gates new work with."
- `docs/problems/` contains current audit; `docs/problems-archive-
  v1-modules/` contains the prior module audit whose recommendations
  were ignored.
- `.claude/skills/` is the on-demand-knowledge surface; nothing
  today couples a skill to a per-PR gate decision.
- Existing ecosystem: `mix credo` with project-specific check
  modules; `sobelow` for static security checks (similar enforcement
  shape); GitHub Code Scanning SARIF ingestion; existing
  `polya-audit` plugin in this repo at
  `.claude/plugins/polya-audit/`.

## Failure classes addressed (from root §Hypothesis)

- **#10** (primary) — prior audit recommendations not ingested;
  authoring an audit must guarantee mechanical enforcement on the
  next applicable PR. This leaf owns the *ingestion* surface; the
  pre-merge-code-gates sibling owns the *execution* of the check
  once it is registered.
- **#2** (cumulative) — the specific manifestation of #10 today is
  rescue-site accumulation; this leaf ensures the rescue-site audit
  becomes a binding gate input rather than prose.

## Complecting hypothesis

- "An audit finding exists" is complected with "an enforcement
  exists" because the only link is human discipline: a human reads
  the audit, decides it matters, writes a check by hand, wires it
  into CI. Decoupling requires that audit findings be *structured*
  (parseable) and that structured findings *automatically* produce
  check registrations.
- "Remediation of an audit finding" is complected with "the audit
  being closed" because v1 has no machine-readable waiver / expiry
  format; mechanical lifecycle requires each finding to carry
  status, surface, and either remediation-PR-link or
  waiver-with-expiry as structured fields.
- "Which gate runs on which PR" is complected with "the PR's diff"
  because today the gates run on every PR universally; an audit
  finding scoped to a particular module surface needs the gate to
  consult a per-PR applicability filter (diff intersects the
  finding's surface manifest).

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The factory specification names a mechanism such that: (a) audit
findings are written in a structured format (a YAML/JSON
frontmatter block, or a sidecar manifest per finding) carrying at
minimum: a unique finding-id, the surface manifest (file
paths/globs, module names, AST patterns), the invariant
asserted/violated, status (`open` | `remediated` | `waived`), and
(for `waived`) an expiry date and waiver rationale; (b) a registry
component (e.g. `Tau.Factory.AuditRegistry` or a static manifest
file under `priv/` produced by a `mix tau.audit.compile` task)
loads every open audit finding from `docs/problems/`,
`docs/problems-archive-v1-modules/`, ADRs marked open, and
SPEC §3 entries marked as recently-added, and exposes them as
inputs to pre-merge-code-gates; (c) an audit finding's
applicability per PR is computed deterministically from the
finding's surface manifest intersected with the PR diff — when
the diff touches the surface and the finding is `open`, the
relevant code gate (e.g. NoRescue) MUST run against the diff for
that finding's scope and MUST fail the PR if the violation
persists, with no per-PR opt-out (only the structured waiver-with-
expiry mechanism lets a PR proceed without remediation); (d)
authoring a new finding (committing a new file with the
structured format) is a no-op until merged, and once merged is
automatically in-force on the next PR — verified by a meta-test
that adds a synthetic finding to the registry and confirms it
fires on a probe PR; (e) the initial population of the registry
explicitly includes the existing audit findings from
`docs/problems/` and the seven flagged `rescue` sites from
`docs/problems-archive-v1-modules/` (root §Acceptance F); (f) the
design records reuse vs build per component (`mix credo`'s
configurable checks + custom check modules? a `polya-audit`
plugin extension? Sobelow-style rule modules? GitHub Code
Scanning SARIF round-trip?) per root §Acceptance D; (g) the spec
output identifies concrete artifacts: the finding format schema,
the registry module/manifest, the `mix tau.audit.compile` task,
the integration points into pre-merge-code-gates' check inputs,
any plugin or hook that auto-registers findings on commit, the
meta-test, and dashboard fields surfacing "audit findings open /
waived / remediated count."

## Out of scope

- The execution mechanism of any individual code-shape check
  (rescue/behaviour/capability/telemetry) — owned by
  **pre-merge-code-gates** sibling (this leaf delivers the
  *inputs*; that leaf runs the checks).
- Cross-document drift on `main` (SPEC-vs-SPEC, ADR supersession)
  — owned by **post-merge-cross-artifact-coherence** sibling.
- AC-binding mechanics — owned by **intent-capture-and-ac-binding**
  sibling.
- Gate infrastructure (silent-skip impossibility, evidence trust)
  — owned by **pre-merge-evidence-and-skip-integrity** sibling.
- Worktree hygiene / dashboards — owned by
  **operability-and-hygiene-enforcement** sibling.
- The workstream-2 corrective-actions catalogue itself (this leaf
  ensures the catalogue is *processed* by the factory; the
  catalogue's content is out of scope per root).
- Documentation-only components; agent-discipline-only
  enforcement.

## Amendment log

- (none yet)
