# ADR-0023 — Documentation taxonomy: durable docs describe intent, never state

**Status:** Accepted

**Date:** 2026-05-22

## Context

A full audit (see Step 1 of the documentation reconciliation; transient file at `docs/audit/AUDIT.md`) found ≥150 distinct discrepancies in this repo's durable documentation. The dominant defect class is **embedded current-state commentary in durable artifacts**:

- `MISSION.md`'s "Verified state (2026-05-04)" remained as the answer to "is the TUI working" through 18 days and 11 self-edits, while CI's `mix tau.tui_ux` was already verifying AC-H1..H4 green on every PR.
- SPEC files carry status headers (`"Status: Draft — #374 implementation PR open"`) that go stale the moment the PR merges.
- ADRs are marked `Proposed` for features that have already shipped.
- `@moduledoc` strings in ~95 of 187 `.ex` files embed issue numbers, PR phases, milestone refs, and SPEC cross-references as narrative prose; these drift as the referenced artifacts close, rename, or change.
- `.claude/logs/solution-tree.json` accumulates ~90 ad-hoc keys duplicating data that GitHub already holds authoritatively.
- A coordinator session has already produced provably wrong recommendations by reading stale state from `MISSION.md` and reasoning from it — the exact failure mode this ADR exists to prevent.

The root cause is structural: when a write-once durable artifact records a point-in-time fact, that fact is stale by construction the moment the underlying state moves. No amount of "remember to update" discipline survives. The fix is not better discipline — it is moving state out of durable artifacts entirely.

## Decision

### Governing invariant

**Durable documentation describes intent, design, and contracts. It never embeds current state.**

State — counts, statuses, dates, "currently", "as of", "verified", "open issues", "M2 in progress", "Phase 2 pending", line numbers, branch names, PR phase markers — lives only in systems of record. Durable docs may *link* to a system of record; they may not *copy* from it.

### Documentation layers

This taxonomy fixes seven layers. Each layer has one job and one allowed content kind.

#### Layer 1 — Mission (`docs/MISSION.md`)

**Role.** One file, ≤1 page, names what Tau is and what "shipping" means. The single artifact `CLAUDE.md` and `TAU.md` direct every agent to read first.

**Contains.** A one-paragraph mission statement. The current milestone *by name only*, linked to its GitHub milestone. A short pointer list to the rest of this taxonomy.

**Forbidden.** Verified-state tables. Action ladders. Branch tables. Failure logs. Count snapshots. "As of" dates. Test counts. Test-suite numbers. Anything that a future commit could falsify.

#### Layer 2 — Project overview (`docs/PROJECT.md`)

**Role.** A map of the repo: directory layout described by purpose, not by inventory; the stack; the build/test/lint commands.

**Contains.** Conceptual layout ("`lib/tau/providers/` — provider adapters"), command invocations, links to milestones / specs / ADRs.

**Forbidden.** Hard counts ("four providers"). Enumerations of files that will grow ("`{anthropic, gemini, bedrock, openai}.ex`"). Milestone status tables — name the milestone, link to GitHub.

#### Layer 3 — Architecture Decision Records (`docs/adr/`)

**Role.** Record an accepted architectural decision and the alternatives considered.

**Contains.** Status (one of: `Accepted`, `Superseded by ADR-NNNN`, `Withdrawn`). Context (the constraints that forced a decision). Decision (the rule the codebase now follows). Consequences. References to other ADRs and SPECs by identifier.

**Forbidden.** `Proposed` status. (A proposed decision is a PR, not an ADR. ADRs land when accepted.) Implementation status ("not yet implemented", "Phase 2 pending"). References to specific issue numbers as decision provenance — git history is the provenance store; the ADR records the decision, not the path that produced it.

#### Layer 4 — Specifications (`docs/spec/SPEC-*.md`)

**Role.** Specify the boundary contract of a coordination-heavy component: constraints, invariants, acceptance criteria, behavioural guarantees.

**Contains.** Constraints (`[Cn-Bm]`), runtime invariants (`D-NNN`), acceptance criteria (`AC-N`). Contracts naming modules, functions, and arities. A source map at the end naming *modules and functions* (stable identifiers), not `file:line` (unstable, drifts).

**Forbidden.** Status headers (`"Status: Draft — PR open"`). `file:line` references in source maps. Acceptance-criterion pass/fail markers in the SPEC text — pass/fail lives in CI. "As of <date>" markers. Tracking-issue PR-phase narration. Internal milestone references ("PR-A merged, PR-B pending"). The SPEC is versioned by git; that is the only versioning it has.

#### Layer 5 — Rules and conventions (`.claude/rules/`, root `CLAUDE.md`, `TAU.md`)

**Role.** Describe the conventions agents must follow. Behaviour-shaping prose for the coordinator.

**Contains.** Invariants the agent must honour (OTP non-negotiables; worktree discipline; spec-before-code). Procedures (factory-loop cycle, gating). References to other rules and skills by name.

**Forbidden.** "Empirically verified 2026-05-20" history footnotes. Issue-number narration in the rule body. `as-of` dates. References to specific files that may move or be renamed without redirecting through a stable name.

#### Layer 6 — Code documentation (`@moduledoc`, `@doc`, `@typedoc` in `lib/`, `web/lib/`, `test/`)

**Role.** State the module's purpose and the contract of each public function.

**Contract — `@moduledoc`.** One to three sentences. What the module is, the role it plays. Behaviour conformance (`implements Tau.Provider`). Nothing else.

**Contract — `@doc`.** Clojure-core inline-doc style: "Takes A, returns B. Raises C when …". Terse and behavioural. Examples are permitted when non-obvious. Function contracts may be expressed in `@doc` prose **or** in `@spec` (preferred for type-shape contracts).

**Contract — `@typedoc`.** Required for every `@type`. One sentence per type.

**Forbidden in any code documentation.** Issue numbers as narrative (`"(issue #191)"`, `"PR-B of 2"`). Dates (`"May 2026"`, `"2026-05-20"`). Milestone refs (`"M6+"`, `"M12"`). Phase markers (`"Phase 1B"`, `"Phase 2 pending"`). Status commentary (`"after this PR"`, `"a follow-up issue tracks…"`, `"Status: pending"`). SPEC/ADR cross-refs **as narrative** (a SPEC `[Cn-Bm]` tag is acceptable as an *identifier reference* when it names the contract the function honours; a sentence of narrative *about* the SPEC is not). Future-tense claims about unshipped work. Historical-bug references (`"fixes #334"`).

#### Layer 7 — Inline comments (`#` in `.ex`)

**Role.** Explain non-obvious *why*. Nothing else.

**Permitted (Cat-1).** Why an ordering matters. Why a clause must come before another. Why a workaround exists. Why a constraint is non-obvious from the code alone.

**Forbidden.**
- WHAT-narration (`# Drop the late timeout` adjacent to code that does exactly that — Cat-2).
- State/history narration (`# ADR-0017: cooperative cancellation flag.`, `# D-027 / #312: bumped from 20 to 100.` — Cat-3). Stable identifier references *without narrative* are acceptable in `@spec`/`@doc`, not in inline comments.
- Commented-out code (Cat-4) — including Phoenix scaffold defaults.

Style: terse. Prefer a five-word comment to a five-line one. If the comment is longer than the code it explains, the code probably needs a name change, not a comment.

### Systems of record for state

| State | System of record | Read via |
|---|---|---|
| Issues, PRs, milestones, project items | GitHub | `gh ... --state all` |
| Branch existence and history | `git` | `git branch -a`, `git log` |
| "Does it work" (verified status) | CI (`binary-qa`, `mix tau.tui_ux`, etc.) | `gh pr checks`, `gh run view` |
| Test counts, coverage | CI job output | the CI run |
| Code identifiers (modules, functions, types) | The code | `grep -rn`, the compiler |
| Per-agent runtime state | Hyperagent archive (its own files) | the archive's own readers |
| Coordinator session work history | `git log`, `gh` PR/issue comments | the same |

Durable docs MAY link to a system of record (a `gh issue` URL, a CI job name, a milestone). Durable docs MAY NOT copy current values from one.

### Artifact-by-artifact ruling (derived from the taxonomy)

- **`MISSION.md`** — Rewrite under Layer 1. Drop verified-state table, branch table, action ladder, "Open issues blocking the mission" section, "Failure log — 2026-05-04 session", D-NNN registry detail (which belongs in SPECs), and stale parentheticals. Keep mission paragraph + a pointer list.
- **`CLAUDE.md` / `TAU.md`** — Layer 5. Remove stale current-state commentary (`"not yet merged to main"`, `"D-001…D-019 are taken"`). Keep rule pointers and conventions.
- **`docs/PROJECT.md`** — Layer 2 rewrite. Replace counts with concepts; replace inventories with directory-purpose descriptions; link milestones to GitHub.
- **ADRs marked `Proposed` for shipped features (`ADR-0014`, `ADR-0015`)** — promote to `Accepted` and remove forward-looking language.
- **`ADR-0008/0009/0011/0014/0016/0018/0019/0022`** — patch the specific factual errors named in audit findings A059–A067; do not embed the present-day count of providers, FSM states, or supervisor positions.
- **`docs/adr/README.md`** — derive the index from the directory (`ls docs/adr/0*.md`) rather than maintaining by hand, or accept it as a hand-maintained index but treat it as Layer 3 metadata (no statuses, just names).
- **SPECs** — Drop status headers. Replace Appendix-B `file:line` source maps with module/function name lists. Resolve internal inconsistencies (A041/A042 etc.). Move "currently on branch X" notes out — those belong (if anywhere) in the PR description, not the SPEC.
- **`docs/olog/tau-system.olog.md`** — A categorical-model snapshot is fundamentally a state artifact. Two options: (a) move under `docs/history/` and treat as a frozen reference; (b) regenerate on-demand and never commit. Default: (a) — move and mark frozen.
- **`docs/m1-verification/`** — M1 is closed. Move to `docs/history/m1-verification/` and freeze; delete `.README.md.swp` (committed editor swap file).
- **`.claude/logs/solution-tree.json`** — Delete. It duplicates GitHub at a stale snapshot. The coordinator's session memory across compactions can be recovered from `git log` and `gh` PR/issue history.
- **`.claude/work-records/`** — Either (a) re-enable emission and keep it as a machine-only artifact never read by humans for state, or (b) delete the directory and remove all references in `critic.md`, `reviewer.md`, and `hyperagents-eval/`. Default: (b) — emission has been dead 8 days while still referenced as live; the live references are the bug.
- **`.claude/operators/README.md`** — Either auto-generate from the `*.id` files or delete.
- **`.claude/skills/*`** — Strip embedded status commentary (issue-number narration, "ADR-0001..ADR-0017 at time of writing" counts). Where a skill must reference a count, derive it ("see `docs/adr/`").
- **`.claude/agents/*`** — Strip "(PR-B / issue #370)" parentheticals; the mechanism is shipped and the issue is closed.
- **`.claude/commands/{pr,clear-logs,harness-status}.md`** — Update to actual `solution-tree.json` schema, OR (preferred, given the solution-tree.json deletion above) rewrite to not consult it. The commands operate against GitHub directly.
- **Code documentation across `lib/` and `web/lib/`** — Bulk pass per Layer 6 and Layer 7. Fix the four factual errors (A104–A107). Convert `@moduledoc` and `@doc` strings to the contract above. Strip Cat-3 inline comments. Replace `# ADR-0017: cooperative cancellation flag.` style narration with whatever WHY a future maintainer actually needs (often: nothing — the function name + `@spec` is the contract).

### Comment standard for Step 4 (`mix format`-compatible)

The Step 4 sweep applies Layer 6 and Layer 7. For each `.ex` file:

1. `@moduledoc` — rewrite to 1–3 sentences per Layer 6 contract; strip embedded state.
2. `@doc` — rewrite each to Clojure-core terse-behavioural style; strip embedded state. Function contracts move to `@spec` (preferred) or stay as terse `@doc` prose.
3. `@typedoc` — add where missing; one sentence each.
4. Inline comments — classify each into Cat-1/2/3/4 per Layer 7. Keep Cat-1. Delete Cat-2, Cat-3 (narrative cross-refs — keep the underlying identifier reference only if it appears in a `@spec` or `@doc` with no narrative), and Cat-4.
5. Run `mix format` and `mix credo --strict` after each module's sweep.

### Enforcement

The taxonomy is normative; this ADR does not prescribe a mechanical enforcement gate. Two non-prescriptive options exist:

- A pre-merge `mix tau.docs.lint` task could flag `@moduledoc`/`@doc` strings containing forbidden substrings (`#NNN`, `as of`, `Phase`, `PR-`, `Status:`, `M[0-9]`, `pending`).
- The existing `critic` gate could be briefed on this ADR.

Adopting either is out of scope for ADR-0023. The fact that the audit produced 150 findings without a gate suggests adding a gate is premature; the right next step is the one-time reconciliation. If embedded state regrows after Step 3 + Step 4 land, the data will support a gate decision then.

## Consequences

### Positive

- The next coordinator session that reads `MISSION.md` will not be misled by a 2026-05-04 verified-state snapshot. It will read intent and link out to current state.
- SPEC source maps stop drifting on every code change — module/function name references are stable; line numbers are not.
- `@moduledoc` strings stop accumulating PR phase markers and issue narrative. Future readers see contract, not commit history.
- The solution-tree-ish duplication of GitHub state ends; the coordinator queries `gh` directly.
- A new defect ("embedded state in durable doc") is now nameable and rejectable at review.

### Negative

- A large one-time reconciliation effort: ≥150 audit findings convert to work items (Step 3) and a codebase-wide comment sweep (Step 4). The effort is bounded — the work-item set is the audit's row count — but it is real work that displaces feature work.
- Some information currently embedded in docs becomes harder to find (e.g. "which PR shipped this?" — answer: `git log -p` or `gh pr list`). This is a deliberate trade: the data has not gone away; it has moved to its system of record.
- ADRs lose the `Proposed` lifecycle, narrowing what an ADR can be. Decisions in flight live in PRs until they are accepted. This may surprise contributors expecting an ADR to record a proposal.

### Out of scope

- A documentation-linter gate (deferred until needed; see "Enforcement").
- Regenerating `docs/olog/` against current HEAD (deferred to a separate work item if anyone needs the model).
- Migrating PR descriptions to the same standard. PR descriptions are transient and not durable docs; the taxonomy does not apply.

## Related

- `docs/audit/AUDIT.md` — the audit findings this ADR is the structural answer to. Transient working file; deleted after Step 3.
- ADR-0001 — issue-driven backlog (the original "state lives in GitHub" decision, which this ADR generalises).
- The Step 3 work item set, to be filed from `AUDIT.md`'s rows.
- The Step 4 comment-rationalization sweep, governed by Layers 6 and 7 above.
