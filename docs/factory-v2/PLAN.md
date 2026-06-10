# Factory v2 — plan

## Why

The trustworthiness audit (`docs/problems/`) returned 11 untrustworthy +
9 partially-trustworthy + 0 trustworthy across 20 independent sub-verdicts
spanning five dimensions of code quality. The coherent emerging signal:

- **Where the compiler / Dialyzer / behaviour callback presence enforces
  the claim, the code conforms.**
- **Where the claim is prose, ADR, SPEC §4 enumeration, NN #7 conformance,
  factory-loop gate enforcement, or telemetry-consumer presence, the
  code drifts.**

The current factory loop has itself collapsed: the four most recent merges
(#411-#414) bypassed the gate with red CI checks; PR bodies cite local
`mix` output as "gate output" while the SHA shows failing jobs; the prior
module audit's recommendations have not landed; new rescue / catch
violations accumulate. The factory's stated discipline is no longer
enforced by anything the factory itself runs.

Two workstreams follow.

## Workstream 1 — Design and build a software factory that survives the
## failure modes the audit found

### First-principles framing

The factory's job is to take user intent and produce code that
*structurally cannot* exhibit the failure classes the audit catalogued.
Where prior factory iterations relied on agent discipline or human review
to enforce a rule, the v2 factory must lift the rule into a mechanical
gate that runs before merge and cannot be silent-skipped.

Failure classes the v2 factory must make impossible (or surface
unambiguously):

1. Documented contracts (`@spec`, `@behaviour`, SPEC §4) drifting from
   code.
2. Cargo-cult `try/rescue` / `catch :exit` / `with else` arms defending
   against conditions that cannot arise.
3. Capability declarations (`prompt_caching: true`) without callback
   implementations.
4. Telemetry events emitted without production consumers.
5. CI gates whose only failure mode is opt-out (silent-skip on empty
   declarations, `|| true` continuations).
6. PRs declaring `AC-N` advances whose tests never invoke the
   user-visible path that the `AC-N` names.
7. Factory-loop merges that proceed with red CI; PR-body fields
   accepting local-machine claims as evidence.
8. Worktree leaks, orphan branches, and stale-`main` collisions.
9. SPEC self-contradictions persisting because no consistency check
   runs.
10. Audit / decision archaeology rotting because the factory doesn't
    re-read prior audits before authoring new code.

### Process — Polya from first principles

The factory design itself is a Polya problem. Apply the framework:

- **Root problem** (`docs/factory-v2/design/problem.md`): what does a
  software factory for Tau need such that the v1 collapse modes become
  structurally impossible?
- **Decomposition** (dimensions of factory capability):
  - Planning & decomposition (how do user intents become PR-shaped work?)
  - Pre-merge gating (what mechanically prevents merge of bad work?)
  - Post-merge enforcement (what catches what slipped through?)
  - Knowledge / memory (how does the factory remember audits, ADRs,
    SPECs, prior failures?)
  - Observability of factory state (how does the operator know if
    discipline is intact, and when it slips?)
  - Recovery (what happens when the discipline IS slipping?)
- **Proposers per leaf** (4 distinct methods including ecosystem-research):
  - First-principles design.
  - Adapt-from-Claude-Code-ecosystem (research existing plugins / skills
    / agents — the user explicitly asked "what can we use from outside").
  - Adapt-from-prior-art (other software-factory patterns: factor-of-100
    cycle-time projects, ASIC-style tape-out gating, security-incident
    response).
  - Adversarial — design the failure mode the factory must catch, then
    work backwards to the gate.
- **Selector** synthesises into one factory-component spec per leaf.
- **Validator** attempts to falsify the spec.
- **Root selector** integrates into a single factory specification.

### Build

Once the design returns:

- Author the plugins / agents / skills / settings / CI workflows the
  spec calls for. Place under `.claude/plugins/factory-v2/` (or split
  into a small number of named plugins).
- Wire the gates into `.github/workflows/`.
- Document each component's contract.
- The build is structural — no aspirational text, only mechanism.

## Workstream 2 — Corrective-actions catalogue (input to the v2 factory)

Separately, the audit's findings become the factory's initial backlog —
not a backlog the user has to read and prioritise, but a catalogue the
factory itself ingests as input to its first run.

Filed at `docs/factory-v2/corrective-actions.md` (forthcoming). Each
entry names: (i) what failed, (ii) the gate that would have prevented
it, (iii) the v2-factory mechanism that closes the class. Not a fix
list — a class-of-failure inventory mapped onto v2 mechanisms.

## Order of operations

1. Bootstrap the Polya design cycle for workstream 1 (root problem.md,
   decomposer, then proposers per leaf).
2. While the design cycle runs, author workstream 2's catalogue from
   the audit's evidence (direct enumeration; no Polya — the audit
   already validated each class).
3. While the design cycle runs, dispatch a research pass on the
   Claude Code OSS plugin / agent / skill ecosystem (input to
   workstream 1's "adapt-from-ecosystem" proposer).
4. When the design selectors return, build the factory.
5. Do not pause for user permission.
