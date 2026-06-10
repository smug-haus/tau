---
template_version: 1
template_name: solution
parent_problem: ./problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-1.md, proposals/proposal-4.md]
selection_method: hybrid
revision: 0
---

# Solution: Tau.Providers.Auth shared resolver + documented policy + telemetry regression test

## Recommendation

Extract a single `Tau.Providers.Auth` module that owns the canonical
`opt → app_env → vault → system_env` chain as in Proposal 1, migrate every
standard API-key adapter (Mistral, DeepSeek, Groq, AzureOpenAI, Custom, Gemini)
to call it (deleting all `Code.ensure_loaded?(Tau.Settings.Vault)` guards),
and add the missing vault leg to Gemini. From Proposal 4, also land a
short `docs/adr/ADR-00XX-auth-resolution-policy.md` documenting the chain
plus the per-adapter exception table (Bedrock AWS-triple, Anthropic OAuth,
Copilot two-token, Azure non-key fields, Custom `base_url`), and add a
cross-adapter `auth_policy_test.exs` that uses `[:tau, :vault, :get]`
telemetry to assert every listed adapter consults vault during credential
resolution. Bedrock and Copilot are explicitly out of the shared chain; the
ADR table is their compliance record. The `configure/1` callback is
**left alone** in this PR (it remains optional/unused) — promoting it is
Proposal 2's larger refactor and is not required by the acceptance criterion.

## Selected from

- **Chosen:** hybrid of `proposals/proposal-1.md` (extraction) and
  `proposals/proposal-4.md` (policy doc + telemetry test).
- **Why chosen:** Proposal 1 has the deepest decomplecting on the control
  flow axis — it actually removes the duplicated chain logic and the
  `Code.ensure_loaded?` guards, giving "one place to test, one place to
  fix" for the standard API-key case. Proposal 4 alone scores lower on
  decomplecting depth ("the woven concern is fine if each is correct" —
  acceptable but leaves the future-adapter footgun open). However,
  Proposal 4's two non-extraction artifacts — the policy ADR and the
  telemetry regression test — fill real gaps Proposal 1 leaves: the ADR
  is the operator-readable artifact the acceptance criterion explicitly
  asks for ("predict without reading each adapter's source"), and the
  telemetry test mechanically catches future adapters that bypass
  `Tau.Providers.Auth`. Proposal 2 (promote `configure/1` to mandatory)
  is rejected because it breaks the `Tau.Provider` behaviour for every
  external implementor and forces Bedrock/Replay into an awkward
  override-only shape — high cost, hard reversibility, and the
  `__using__`-with-module-attributes inversion is more implicit than
  Proposal 1's explicit parameter passing. Proposal 3 (Auth.Spec struct
  + Mix task) is rejected for medium-high cost on three new artifacts,
  Azure's multi-field gap unaddressed by a single-field Spec, and
  reliance on a `known_adapters/0` registry that does not exist.

### Scoring table

| # | Fit       | Decomplecting depth | Migration cost | Risk   | Reversibility |
|---|-----------|---------------------|----------------|--------|---------------|
| 1 | Yes       | Substantial         | Low            | Low    | Easy          |
| 2 | Yes       | Deep                | High           | Medium | Hard          |
| 3 | Yes       | Deep                | Medium-High    | Medium | Medium        |
| 4 | Partially | Surface             | Low            | Low    | Easy          |

Hybrid 1+4: Yes / Substantial / Low / Low / Easy — strictly dominates
either alone on the relevant axes.

## What changes

- **New file** `lib/tau/providers/auth.ex` — the
  `Tau.Providers.Auth.resolve_api_key/3` and
  `resolve_api_key_or_error/3` functions from Proposal 1's sketch.
  Unconditional `Tau.Settings.Vault.resolve/1` call (no
  `Code.ensure_loaded?` guard).
- **Modified** `lib/tau/providers/mistral.ex`,
  `lib/tau/providers/deepseek.ex`, `lib/tau/providers/groq.ex` — delete
  private `vault_key/0`; simplify `api_key/0` to call
  `Tau.Providers.Auth.resolve_api_key(__MODULE__, "<NAME>", "<NAME>")`.
- **Modified** `lib/tau/providers/azure_openai.ex` — replace the
  `:api_key` leg of `resolve_config/0` with a call to
  `Tau.Providers.Auth`. `endpoint`, `deployment`, `api_version` keep
  their current resolution (no vault leg) and are recorded as exceptions
  in the ADR table.
- **Modified** `lib/tau/providers/custom.ex` — same pattern as Azure for
  the `:api_key` leg; `base_url` keeps its current resolution and is
  recorded as an exception.
- **Modified** `lib/tau/providers/gemini.ex` — add the missing vault leg
  via `Tau.Providers.Auth.resolve_api_key(__MODULE__, "GOOGLE_API_KEY",
  "GOOGLE_API_KEY")`, then keep the existing `GEMINI_API_KEY` fallback
  via a small adapter-specific `||` after the shared call.
- **New file** `docs/adr/ADR-00XX-auth-resolution-policy.md` — states
  the four-step chain (`opt → app_env → vault → system_env`) and the
  per-adapter exception table (Anthropic, Bedrock, Copilot, Azure
  non-key fields, Custom `base_url`).
- **New file** `test/tau/providers/auth_test.exs` — unit + property
  tests for `Tau.Providers.Auth` itself (chain order, empty-string
  rejection, missing-key error tuple).
- **New file** `test/tau/providers/auth_policy_test.exs` — Proposal 4's
  cross-adapter telemetry test: for each adapter in the standard list,
  assert that `[:tau, :vault, :get]` fires during credential resolution.

## What does not change

- The `Tau.Provider` behaviour and its `@optional_callbacks` list,
  including `configure/1`. The dead-interface second complecting
  hypothesis is acknowledged but **not** fixed in this PR; that is a
  separate decision (Proposal 2's scope) and would force breaking
  changes on every external `@behaviour Tau.Provider` implementor.
- `lib/tau/providers/anthropic.ex` and
  `lib/tau/providers/anthropic/auth.ex` — Anthropic continues to use
  its dedicated OAuth-capable `Auth` module. It is the ADR's first
  exception row.
- `lib/tau/providers/bedrock.ex` — the AWS key triple plus optional
  `:aws_credentials` library leg stays in place. Bedrock is the ADR's
  second exception row; vault integration for Bedrock is left as a
  separate scope per the problem's out-of-scope note.
- `lib/tau/providers/copilot/auth.ex` — the two-token OAuth model is
  unchanged; Copilot is documented as the third exception.
- The `Tau.Settings.Vault` module itself, the Replay adapter, and any
  test doubles of `Tau.Provider`.
- The `Tau.Provider.Event` shape and all stream-event semantics.

## Migration sketch

Single PR, reviewable in one pass. Sequence:

1. Add `lib/tau/providers/auth.ex` with the two public functions and the
   unit test file `test/tau/providers/auth_test.exs`. Run
   `mix test test/tau/providers/auth_test.exs` to confirm the shared
   module works in isolation.
2. Migrate the five guarded adapters one at a time
   (`mistral → deepseek → groq → azure_openai → custom`); each migration
   is a self-contained commit deleting the private `vault_key/0` and
   replacing the call site. Run the per-adapter test suite after each.
3. Add the missing vault leg to `gemini.ex` as a separate commit.
4. Add the ADR (`docs/adr/ADR-00XX-auth-resolution-policy.md`) including
   the per-adapter exception table.
5. Add `test/tau/providers/auth_policy_test.exs` as the cross-adapter
   telemetry regression gate; ensure it covers all eight standard
   adapters (Mistral, DeepSeek, Groq, Azure, Custom, Gemini, plus
   Anthropic via its own `Auth` module — Anthropic is included because
   its `Auth.resolve/1` does call `Tau.Settings.Vault`). Bedrock and
   Copilot are explicitly skipped per the ADR exception table.
6. Run `mix compile --warnings-as-errors`, `mix test`,
   `mix credo --strict`, `mix dialyzer`. No baseline rebuild expected
   because the behaviour is unchanged.

Reversal cost is low: the shared module can be deleted and the private
helpers restored from VCS if the extraction is later judged wrong; the
ADR and telemetry test would survive the reversal as a documentation
and regression-gate layer.

## Open questions

- Does `Tau.Settings.Vault` compile unconditionally in every mix env
  used by Tau today? Proposal 1's confidence rests on this. A
  `mix compile --no-deps-check` in a fresh env without optional deps
  must succeed for the `Code.ensure_loaded?` guard removal to be safe.
  The validator should falsify by checking `mix.exs` for any
  conditional-compile block guarding `Tau.Settings.Vault`.
- Should the `Tau.Providers.Auth.resolve_api_key/3` signature accept a
  single struct (Proposal 3's `Auth.Spec`) instead of three positional
  arguments? This solution keeps the positional shape for simplicity,
  but if a future fourth or fifth parameter is needed (e.g. opt-key
  override, multiple env-var fallbacks for Gemini), refactoring to a
  struct would be the natural next move.
- Is the telemetry-based test (Proposal 4's weakness) sufficient to
  catch future regressions, given it asserts only that vault is
  *called*, not that its return value is *used*? Strengthening to a
  stub-based assertion (mock `Vault.resolve/1` and assert the returned
  value flows into the outbound request body) is a desirable upgrade
  but out of scope for this PR; the telemetry assertion is the floor.
- Does the `configure/1` dead callback warrant its own follow-up issue
  now, or wait until a concrete need arises? The acceptance criterion
  does not require resolving it; this solution defers.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Tau.Providers.Auth shared utility module
  (extraction; chosen for its deep decomplecting on the standard chain).
- `proposals/proposal-2.md` — Promote configure/1 to mandatory callback
  (rejected: high migration cost, API breakage, awkward `__using__`
  inversion).
- `proposals/proposal-3.md` — Auth.Spec data-shape contract + Mix-task
  assertion (rejected: medium-high cost on three new artifacts,
  unresolved adapter-discovery mechanism, Azure multi-field gap).
- `proposals/proposal-4.md` — Document-only policy + telemetry test
  (chosen for the ADR artifact and the telemetry regression test;
  Proposal 4's "no extraction" stance is rejected, but its non-code
  artifacts are kept).

## Revision history

- (revision 0 — initial)
