---
template_version: 1
template_name: solution
parent_problem: problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md]
selection_method: single
revision: 0
---

# Solution: Shared config module binds the Finch pool name at both sites

## Recommendation

Introduce `Tau.Providers.Config` (a new ~10-line module in
`lib/tau/providers/config.ex`) that exposes `finch_name/0` returning the
atom `Tau.Providers.Finch`. Update `Tau.Application` and
`Tau.Memory.EmbeddingWorker` to reference `Tau.Providers.Config.finch_name()`
as the default. The `Application.get_env/3` runtime-override escape hatch is
retained in `EmbeddingWorker`; its default argument now derives from the shared
function rather than a bare atom. This eliminates the two-site drift by making
them structurally dependent on a single authoritative constant.

## Selected from

- **Chosen:** `proposals/proposal-2.md` (Option B — dedicated config module)
- **Why chosen:**

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|---------------|------|---------------|
| 1 | Yes | Surface | Low | Low | Easy |
| 2 | Yes | Substantial | Low | Low | Easy |
| 3 | Yes | Deep | Medium | Medium | Easy |
| 4 | Partially | Surface | Low | Medium | Easy |

Proposal 1 satisfies the acceptance criterion but leaves the two atom literals
unbound: the next rename of the pool in `application.ex` silently reproduces the
bug. That residual complecting is not required by the acceptance criterion but
is identified in the problem's complecting hypothesis; fixing only the symptom
scores Surface on decomplecting depth.

Proposal 2 (Option B) satisfies the criterion with the same one-token change at
each site and adds a shared constant that makes future drift a compiler-visible
event (one place to update; every consumer of the constant is then correct).
Cost is marginally higher than Proposal 1 (one new file, ~10 lines) but
negligible. Risk and reversibility are identical to Proposal 1.

Proposal 3 (dependency injection) is technically sounder on purity grounds and
aligns with OTP §8, but requires an API-breaking signature change and updating
every call-site. Medium confidence in the exact call-site count. Its benefit
(eliminating `Application.get_env` from the function body) is not required by
the acceptance criterion. Ruled out: higher cost, medium confidence, no
criterion-level advantage over Proposal 2.

Proposal 4's `config/config.exs` minimal form bypasses the wrong default without
touching source, but does not bind `application.ex` and `embedding_worker.ex`
to each other — the drift seam remains. The `compile_env` hardening adds
test-environment brittleness (dynamic `Application.put_env` in tests is
silently ignored). Ruled out: weaker decomplecting than Proposal 2 with added
risk.

Proposal 2 wins: it is the weakest change that closes the drift seam. The
bias toward decomplecting depth over cost, where the cost delta is negligible,
settles the tie between Proposals 1 and 2 in favour of 2.

## What changes

- **New file** `lib/tau/providers/config.ex` — defines `Tau.Providers.Config`
  with a single `@finch_name Tau.Providers.Finch` module attribute and a
  `def finch_name/0` accessor.
- `lib/tau/application.ex` line 78 — change `{Finch, name: Tau.Providers.Finch}`
  to `{Finch, name: Tau.Providers.Config.finch_name()}`.
- `lib/tau/memory/embedding_worker.ex` line 106 — change the default argument of
  `Application.get_env(:tau, :finch_name, Tau.Finch)` to
  `Application.get_env(:tau, :finch_name, Tau.Providers.Config.finch_name())`.

Three files; net addition of ~10 lines.

## What does not change

- The `Application.get_env/3` lookup in `EmbeddingWorker` — the runtime-override
  escape hatch is preserved for operators who need a custom pool.
- All other supervision tree entries and startup order in `application.ex`.
- The `Tau.Providers.Finch` atom itself — it remains the canonical pool name.
- All callers of `EmbeddingWorker.embed/N` — no signature change.
- Test files — no test that mocks or references the Finch name needs updating
  (the new config module is a thin accessor, not a process).

## Migration sketch

Introduce `lib/tau/providers/config.ex` first (no callers yet; zero risk).
Then update `application.ex` to use `Tau.Providers.Config.finch_name()` —
compile and start the supervision tree to confirm the pool still registers.
Then update `embedding_worker.ex` to use the same accessor as its default.
The change lands in a single PR; no staged rollout required. Revert is one
commit.

## Open questions

- Whether `Tau.Providers.Config` is the correct namespace for this constant
  (alternative: `Tau.Config` or `Tau.Infrastructure`). The problem is narrow
  enough that the choice does not affect correctness; it affects discoverability.
  Defer to project conventions in `lib/tau/providers/`.
- Whether a companion test should assert that
  `Tau.Providers.Config.finch_name()` equals the name registered by
  `Tau.Application` — a property check that future renames cannot silently
  diverge. Not required by the acceptance criterion but would close the last
  nominal-equality gap.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Fix the default atom at the call-site (one-line,
  surface fix, leaves drift seam open)
- `proposals/proposal-2.md` — Shared config module, compile-time binding via
  named constant (selected)
- `proposals/proposal-3.md` — Inject the Finch name via the EmbeddingWorker
  start argument (deep decomplecting, API-breaking, medium cost)
- `proposals/proposal-4.md` — Explicit `config/config.exs` entry with optional
  `compile_env` hardening (surfaces operator config, residual drift risk)

## Revision history

- (revision 0 — initial)
