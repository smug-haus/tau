# SUPERSEDED — see `docs/arch/`

**Status:** superseded 2026-06-10.

The `docs/factory-v2/design/` subtree explored a factory-v2 design built as
**Claude-Code plugins / agents / skills + CI gates** (see `../PLAN.md`,
workstream 1). That substrate decision is **superseded** by `docs/arch/`, which
designs the factory as its **own supervised OTP application** (`:tau_factory`,
`lib/tau/factory/`) — closing GAP-1 (the factory-as-prompt-loop) at the root
rather than hardening the prose loop. This was decided with the operator
("Decision 0": OTP app, not plugins; evolve, not fresh).

**What carries forward (NOT superseded):**

- **The diagnosis.** Both efforts agree the v1 collapse was an *enforcement*
  failure (discipline not enforced by anything the factory runs) — `PLAN.md`'s
  "Why" and the trustworthiness audit are the evidence base.
- **`../corrective-actions/`** — the audit's failure-class catalogue is the new
  factory's **initial backlog** and the set of failure classes the gates must
  close. It is ingested as input to SPEC-FACTORY-GATE and the M10 epic, not
  discarded.
- **The decomposition** (intent-capture, pre-merge gates, knowledge/memory,
  post-merge coherence, operability, evidence-integrity) maps onto the
  `docs/arch/` components; only the plugin *substrate* is replaced.

**Where the live design lives:** `docs/arch/` (requirements → verified system
architecture → concrete OTP software architecture) and
`docs/spec/SPEC-FACTORY-{CORE,MERGE,GATE,FLEET,GOV}.md`.

This directory is retained as **evidence and decision trail**; do not build from
it.
