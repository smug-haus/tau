---
template_version: 1
template_name: problem
node_kind: leaf
mode: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: Post-merge cross-artifact coherence — SPEC↔SPEC, SPEC↔code, ADR↔SPEC drift on `main`

## Statement

Per-PR gates examine a single diff in isolation; they cannot detect
contradictions that emerge between artifacts as two PRs land or that
exist within a single artifact at rest (SPEC-PERMISSION-PROMPTS §4 B5
says 6 modes, §6 D-171 says 3 — v1 lets this persist because no
SPEC-vs-SPEC consistency check runs, root #9). Nor do per-PR gates
detect drift that emerges over time on `main` — a SPEC §4 contract
later contradicted by a code change in an unrelated PR, an ADR
superseded by a later ADR without supersession metadata, or D-NNN
identifiers reused across SPECs. The problem is solved when a `main`-
side check, run on every push to `main` and on a cadence (e.g. daily),
detects every class of cross-artifact contradiction the v1 audit
identified and fails-loud (file an issue, alarm the dashboard) rather
than fails-silent.

## Context

- Root §Hypothesis #9 — SPEC self-contradiction persists because no
  SPEC-vs-SPEC consistency check runs (concrete example:
  SPEC-PERMISSION-PROMPTS §4 B5 vs §6 D-171).
- `CLAUDE.md` D-NNN identifier rule: "Before authoring a new D-NNN,
  verify the identifier is free across the whole repo (`git log --all
  --grep`, plus `grep -rn` over `lib test docs .claude`). Single-branch
  negative results are not evidence of absence." This is the
  uniqueness invariant; no mechanical enforcement today.
- `.claude/rules/spec-before-code.md` catalogs which SPEC §3 invariants
  bind which file paths (Appendix B source-maps); the structured data
  exists, but no check on `main` re-validates that bindings still
  resolve.
- ADR convention is in `docs/adr/README.md`; supersession is
  prose-only.
- Existing ecosystem: `vale` for prose linting, `markdown-link-check`,
  `markdown-it` AST traversal, JSON-schema validation for structured
  blocks within markdown.

## Failure classes addressed (from root §Hypothesis)

- **#9** (primary) — SPEC self-contradiction (within and across SPEC
  documents); D-NNN uniqueness; SPEC §4 contract names refer to
  symbols that still exist after later commits land.
- **#1** (cumulative tail) — contracts drift from code as a function
  of time on `main`, beyond what any single-diff pre-merge check could
  catch (the pre-merge sibling catches per-PR drift; this leaf catches
  drift that emerges from the *combination* of merges).
- **#4** (cumulative tail) — telemetry events that lose their consumer
  on `main` after a later PR removes the handler without removing the
  emission (per-PR check catches only changes within the diff).

## Complecting hypothesis

- "What a SPEC says" is complected with "what the codebase does"
  because the only link is the spec-before-code Appendix B source-map
  written in prose; structured machine resolution requires the
  source-map to be a parseable manifest the check consumes.
- "When a contradiction was introduced" is complected with "which PR
  introduced it" because v1 only catches contradictions per-PR; a
  contradiction that emerges from the *combination* of two PRs is
  invisible to both PRs' gates and so must surface on `main`.
- "D-NNN uniqueness" is complected with "the author remembered to
  grep" because the only check is in CLAUDE.md as a human-directed
  rule; mechanical uniqueness requires a per-`main`-push scan.

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

The factory specification names mechanisms such that: (a) on every
push to `main` (via a workflow triggered on `push: branches: [main]`)
a coherence-check suite runs that includes at minimum: D-NNN
uniqueness across `lib/`, `test/`, `docs/`, `.claude/`; SPEC §4
contract symbol existence (each named module/function/struct/callback
in any SPEC §4 must resolve in the current `main` codebase); SPEC-vs-
SPEC contradiction detection (D-NNN with conflicting definitions,
contradictory invariants on the same surface — the v1 PERMISSION-
PROMPTS B5/D-171 case must be detected by this check on its first
run); ADR supersession integrity (a later ADR claiming to supersede
ADR-N has both directions of the link in the metadata); telemetry-
consumer presence cumulative (per-PR check augmented with a `main`-
side rerun that catches handler-removal-without-emission-removal); (b)
the suite cannot silent-skip per root §Acceptance C — an empty SPEC
catalog or empty ADR set explicitly logs "0 applicable, checked"; (c)
the suite's verdict, when failing, opens a GitHub issue
auto-milestoned to the current focus milestone, with the failing
contradictions enumerated, AND surfaces on the factory dashboard
(operability sibling consumes the verdict); (d) the design records
reuse vs build per check (a `polya-audit`-style plugin? `vale` with
custom styles for SPEC structural rules? a Mix project under `priv/`
that re-uses `Sourceror`? GitHub Code Scanning API?) per root
§Acceptance D; (e) the spec output identifies concrete artifacts:
workflow file (e.g. `.github/workflows/main-coherence.yml`), the mix
task or escript names (`Mix.Tasks.Tau.Coherence.Dnnn`,
`Mix.Tasks.Tau.Coherence.SpecContracts`, etc.), the structured
source-map manifest format (a YAML/JSON sidecar to each SPEC, or
auto-extracted from Appendix B), the issue-opener Action, and any
notification hook.

## Out of scope

- Per-PR pre-merge code-shape checks — owned by
  **pre-merge-code-gates** sibling (this leaf catches what slips
  through *because* the per-PR check can only see one diff at a time).
- Gate-infrastructure invariants — owned by
  **pre-merge-evidence-and-skip-integrity** sibling.
- Ingestion of historical audit findings as new check inputs — owned
  by **knowledge-memory-and-audit-ingestion** sibling (this leaf
  detects *new* contradictions; that leaf ingests *existing* ones).
- AC-test binding mechanics — owned by
  **intent-capture-and-ac-binding** sibling.
- Dashboards and orphan-worktree hygiene — owned by
  **operability-and-hygiene-enforcement** sibling.
- Documentation-only components; agent-discipline-only enforcement;
  workstream-2 corrective-actions catalogue.

## Amendment log

- (none yet)
