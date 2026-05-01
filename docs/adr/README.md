# Architectural Decision Records (ADRs)

This directory holds architectural decision records for Tau. Each ADR
captures one architectural choice — its context, the decision itself,
the consequences, and the alternatives considered.

## Why we keep ADRs

Tau has a small number of non-negotiables (see `CLAUDE.md` /
`TAU.md`) and a much larger number of design decisions that fall
under those rules. The non-negotiables tell you what's _forbidden_;
ADRs tell you what was _chosen_, and why a future change would need
fresh justification.

The trigger for writing an ADR is **any decision a future contributor
(human or agent) is likely to question or accidentally regress**.
Examples:

- An OTP shape that looks redundant ("why is this a process?").
- A behaviour callback that's intentionally optional.
- A field on a public struct that has a hidden contract
  (JSON-encodable, namespaced keys, etc.).
- A naming or layering choice that the obvious refactor would
  invert.

If a decision is captured in inline code comments only, it tends to
get rewritten away by the next refactor. ADRs survive.

## Conventions

- Files are named `NNNN-kebab-case-title.md` where `NNNN` is the
  next four-digit number. Numbers are never reused.
- Every ADR has a **Status** (`Proposed | Accepted | Deprecated |
  Superseded by NNNN`). Once accepted, the body should not be
  rewritten — supersede with a new ADR instead.
- ADRs are short. Two pages is a long ADR. If you need more, write
  the design doc and link it from a short ADR.
- Use `0000-template.md` as the starting point.
- A PR that introduces or changes architecturally significant
  behaviour links to the ADR in its description, and the commit
  message references the ADR number ("ADR-0007").
- Issues that arose from an ADR can mention it in their body
  (`See ADR-0007.`) so the rationale is one click away.

## When NOT to write an ADR

- Bug fixes that don't change the architecture.
- Polish, formatting, doc rewording.
- Adding a tool / hook / extension that uses an existing seam.
- Anything covered explicitly by a non-negotiable (just follow the
  rule; don't ADR-justify obeying it).

## Index

| ADR | Title | Status |
|-----|-------|--------|
| [0001](0001-issue-driven-backlog.md) | GitHub issues are the backlog | Accepted |
| [0002](0002-provider-ctx-is-the-runtime-config-channel.md) | Provider runtime configuration goes through `:provider_ctx`, not `Application` env | Accepted |
| [0003](0003-tool-validator-fails-closed-on-unresolvable-schemas.md) | `Tau.Tool.Validator` fails closed on unresolvable schemas | Accepted |
| [0004](0004-pubsub-at-the-top-of-the-supervision-tree.md) | `Phoenix.PubSub` is at the top of the supervision tree | Accepted |
| [0005](0005-skills-discovery-is-per-session-and-pure.md) | Skills discovery is per-session and side-effect-free | Accepted |
| [0006](0006-defer-tau-memory-cache-until-measured.md) | Defer `Tau.Memory.Cache` until measurements justify it | Accepted |
| [0007](0007-compaction-summaries-survive-recompaction.md) | Compaction summaries are pinned across re-compaction | Accepted |
| [0008](0008-user-code-never-runs-synchronously-in-the-fsm.md) | User code never runs synchronously inside the session FSM | Accepted |
| [0009](0009-user-messages-queue-during-active-turn.md) | User messages queue (postpone) during an active turn | Accepted |
| [0010](0010-cost-tracker-owns-ets-not-state.md) | Cost tracker owns an ETS table, not GenServer state | Accepted |
| [0011](0011-per-provider-rate-limiter-is-stateful-genserver.md) | Per-provider rate limiter is a stateful GenServer (not an ETS-owner) | Accepted |
| [0012](0012-provider-fallback-is-fsm-internal-retry.md) | Provider fallback is an FSM-internal retry, not a wrapper provider | Accepted |

(New ADRs append here. Keep the table sorted by ADR number.)

## References

- Michael Nygard's original ADR write-up:
  https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions
- ADR community templates and tooling:
  https://adr.github.io/
