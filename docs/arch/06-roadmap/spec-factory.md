# SPEC-FACTORY-* — converting this architecture into an enforced SPEC

This architecture spec (`docs/arch/`) is the *design*. To enter the project's
enforced regime it must become one or more `docs/spec/SPEC-FACTORY-*.md` entries
in the canonical §0–§7 + Appendix-B template (research:
`tau-current-analysis.md` §2.9), so the spec-before-code gate
(`.claude/rules/spec-before-code.md`) and the D-NNN discipline apply to the
factory itself — closing GAP-8 (the factory had no spec of its own).

The factory's PSDH triage score is **5/5** (shared mutable state: the repo +
ledger; temporal coupling: gate→merge→health; cross-process coordination:
fleet; feedback loops: refine/pivot + re-gate; state accumulation: solution
tree). It is maximally coordination-heavy — a SPEC is mandatory.

## Proposed SPEC partitioning

One umbrella SPEC is too large to gate in one pass. Partition by the consistency
boundaries the architecture already draws:

| SPEC | Scope | Components | D-NNN block (provisional) |
|------|-------|-----------|---------------------------|
| `SPEC-FACTORY-CORE` | the control loop, escalation, durable ledger | K, S, U, L | D-300..D-323 (control + safety) |
| `SPEC-FACTORY-MERGE` | the serialized integrator | M | D-300..D-303, D-341 (cite-shared) |
| `SPEC-FACTORY-GATE` | gate + toolchain + anti-gaming | G, Toolchain | D-304..D-308, D-322, D-354 |
| `SPEC-FACTORY-FLEET` | isolation + worker lifecycle | W | D-309..D-317, D-334 |
| `SPEC-FACTORY-GOV` | governance, policy, observability | Gov | D-319..D-321, D-350..D-353 |

(D-NNN numbering is provisional — see `../04-software-architecture/
traceability.md`; verify free before adoption.)

## §-template mapping (per SPEC)

The architecture files already contain each section's substance; converting is
re-homing, not re-deriving:

| SPEC § | Source in `docs/arch/` |
|--------|------------------------|
| §0 Why | `00-problem/problem-statement.md` + the founding-failure rationale |
| §1 Triage | 5/5 score above |
| §2 Component decomposition | `03-system-architecture/system-architecture.md` §1 |
| §3 L0 constraints (the 8 elicitation Qs) | `02-requirements/invariants.md` clusters + `nfrs.md` |
| §4 Boundary contracts (B-N) | `03-…/system-architecture.md` §2 composition graph (each edge = a B-N) |
| §5 State enumeration | `04-…/control-plane.md` (U FSM) + `merge-and-integration.md` (M CAS) |
| §6 D-NNN runtime invariants | `04-…/traceability.md` |
| §7 Acceptance criteria (AC-N) | below |
| Appendix B source map | `04-…/traceability.md` module index + D-NNN→module rows |

## Acceptance criteria (AC-N) — the factory's own gate

Each is expressed against the **user-facing path** with an observable signal
(the substance-over-ceremony rule), per `FR-1.4`. These are what a `SPEC-FACTORY`
PR's test-author would write failing tests for first.

- **AC-1 (merge safety).** A unit whose gate verdict is revoked after green and
  before merge is NOT merged. *Signal:* integration test — force a post-green
  revocation; assert no `origin/main` commit and the unit returns to gating.
- **AC-2 (freshness).** A unit gated against a now-superseded `origin/main` is
  rejected at merge and re-gated. *Signal:* advance `origin/main` mid-gate;
  assert `--force-with-lease` rejection, no merge.
- **AC-3 (anti-gaming).** A vacuous gating test (passes against reverted
  production) cannot reach `main`; a malicious toolchain adapter that fakes its
  own test result cannot defeat the mutation gate. *Signal:* the mutation check
  fails the PR; the engine-side parser + failing-id cross-check reject the
  forged artifact.
- **AC-4 (isolation).** Two concurrent workers cannot corrupt each other via a
  shared `$HOME`/cache resource. *Signal:* the Burrito-XDG-race reproduction
  runs clean under per-worker namespacing.
- **AC-5 (no lost work).** A `:kill`ed worker with an untracked new file loses
  nothing. *Signal:* the file is recoverable from the janitor capture.
- **AC-6 (durability).** A coordinator killed immediately after recording a
  decision resumes without re-doing or losing it. *Signal:* restart replays from
  the ledger; the decision appears exactly once.
- **AC-7 (total escalation).** Every non-progress state reaches an operator with
  exactly one named reason. *Signal:* property test — `Escalation.classify/1` is
  total; no reachable spin state.
- **AC-8 (budget ceiling).** Spend never exceeds the configured budget by more
  than one in-flight action. *Signal:* the ledger balance check holds at E-BUDGET.
- **AC-9 (meta — CI gates).** The three mechanical gates run in CI and block.
  *(meta — verified by CI wiring, exempt from the unit-test-linkage check.)*
- **AC-10 (self-hosting smoke).** The factory drives one real PR on its own
  (Elixir bootstrap toolchain) from open issue to merged, gate-green, with
  `main` health-checked. *Signal:* the exact command + the observable merge +
  the green health check — the dogfood proof.

## Relationship to the existing rules

`SPEC-FACTORY-*` does not replace `.claude/rules/factory-loop.md` etc.; it
**supersedes their prose enforcement with structural enforcement**. The
migration appendix (`../04-software-architecture/migration.md`) tabulates each
rule MUST → the D-NNN that now enforces it. The rules remain as operator
documentation; the SPEC + D-NNN + tests are the enforcement.
