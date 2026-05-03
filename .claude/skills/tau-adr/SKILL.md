---
name: tau-adr
description: >
  Use when an architectural decision worth a written record is being made:
  a behaviour callback addition, an OTP shape that looks redundant, a
  public struct's hidden contract, or a layering choice the obvious
  refactor would invert.
---

# tau-adr — when and how to record an architectural decision

The non-negotiables (`.claude/rules/otp-non-negotiables.md`) tell you
what's _forbidden_. ADRs in `docs/adr/` tell you what was _chosen_, and
why a future change would need fresh justification.

## §1 When to file

- A behaviour callback you're tempted to add as `@optional_callbacks` —
  capture why some implementations can skip it.
- An OTP shape that looks redundant (a process where a function would
  do, a registry that's not strictly needed) — explain the reason or
  it'll get refactored away.
- A field on a public struct with a hidden contract (JSON-encodable
  values, namespaced keys, default semantics).
- A naming or layering choice that the obvious refactor would invert.

## §2 When NOT to file

- Anything covered explicitly by a non-negotiable — just follow the
  rule.
- Bug fixes that don't change architecture; polish; doc rewording.

## §3 Procedure

1. Copy `docs/adr/0000-template.md` to the next number
   (`docs/adr/NNNN-kebab-case-title.md`).
2. Fill in: Status, Context, Decision, Consequences, Alternatives.
3. Link the ADR from the PR description.
4. Reference it in the commit message as `ADR-NNNN`.

## §4 Pointers

- **`docs/adr/README.md`** — full conventions (naming, status
  lifecycle, when to supersede, how to index).
- **`docs/adr/`** — the existing ADRs (ADR-0001 through ADR-0017 at the
  time of writing) for examples.
