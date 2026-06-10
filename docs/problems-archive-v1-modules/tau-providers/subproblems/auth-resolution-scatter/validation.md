---
template_version: 1
template_name: validation
parent_solution: ./solution.md
parent_problem: ./problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/3
revision_triggered: none
---

# Validation: Tau.Providers.Auth shared resolver + documented policy + telemetry regression test

## Overview

The solution makes eight checkable propositions: (1) a new
`Tau.Providers.Auth` module owns the canonical
`opt → app_env → vault → system_env` chain; (2) it removes
`Code.ensure_loaded?(Tau.Settings.Vault)` guards in five adapters
(Mistral, DeepSeek, Groq, AzureOpenAI, Custom); (3) Gemini gains a
vault leg via the shared module; (4) an ADR documents the chain and
per-adapter exceptions; (5) a cross-adapter telemetry test asserts
each standard adapter consults vault; (6) the `Tau.Provider` behaviour
(including `configure/1`) is left unchanged; (7) Anthropic continues
using its dedicated `Auth` module without modification; (8) Bedrock
and Copilot are explicitly out of the shared chain and recorded as
exceptions. Falsification proceeded through dependency check
(`Tau.Settings.Vault` first-party status), counter-example construction
(can the shared signature accommodate every cited adapter?), edge-case
enumeration (Gemini's dual env-var fallback, Anthropic's OAuth path,
Copilot's two-token model), and integration check (`[:tau, :vault,
:get]` telemetry event exists). Outcome: seven claims withstood; claim 3
(Gemini vault leg) is partially falsified — Gemini's existing
`GOOGLE_API_KEY || GEMINI_API_KEY` fallback chain requires the
solution's qualifier to be narrowed but does not require revision.

## Toulmin per claim

### Claim 1: A new `Tau.Providers.Auth` module owns the canonical four-step chain `opt → app_env → vault → system_env`, with unconditional `Tau.Settings.Vault.resolve/1` calls and no `Code.ensure_loaded?` guard.

- **Claim (C):** "Extract a single `Tau.Providers.Auth` module that
  owns the canonical `opt → app_env → vault → system_env` chain …
  Unconditional `Tau.Settings.Vault.resolve/1` call (no
  `Code.ensure_loaded?` guard)." (solution.md L14–17, L70–73)
- **Grounds (G):** `lib/tau/settings/vault.ex:1` defines
  `Tau.Settings.Vault` as a first-party module in `lib/`, not a
  dep. The existing Anthropic auth path
  (`lib/tau/providers/anthropic/auth.ex:79–81`) already calls
  `Tau.Settings.Vault.resolve/1` and
  `Tau.Settings.Vault.resolve({:vault, "ANTHROPIC_API_KEY"})`
  unconditionally with no `Code.ensure_loaded?` guard, in production
  code that ships today. `mix.exs:47–136` lists no optional
  declaration around the `Tau.Settings.Vault` module (the module is
  in the project's own `lib/`, not a Hex dep).
- **Warrant (W):** A first-party module compiled in the same Mix
  project is always loaded when the calling module is loaded; the
  BEAM loader does not require a runtime existence check for code in
  the project's own application. `Code.ensure_loaded?/1` is a guard
  only meaningful for optional deps or hot-swap scenarios. Removing
  the guard therefore cannot change behaviour for any production
  build.
- **Qualifier (Q):** Holds for every Mix env that includes
  `elixirc_paths: ["lib", ...]` (all of `:dev`, `:test`, `:prod`
  per `mix.exs:44–45`). Does not extend to a hypothetical extraction
  of `Tau.Settings.Vault` into a separate optional dep — out of
  scope for this PR.
- **Rebuttal (R):** If a future refactor moved `Tau.Settings.Vault`
  into a separate optional package, the unconditional call would
  fail at compile or runtime. The solution does not foresee this;
  if it ever happens, the guard would need to be reintroduced.
- **Backing (B):** ADR-0016 (`docs/adr/0016-credential-custody-is-the-os-not-tau.md`)
  ratifies `Tau.Settings.Vault` as the canonical credential
  resolution path. Elixir/OTP standard module-loading semantics
  (in-project modules are always available when their application
  is loaded).

#### Falsification attempt for claim 1

- **Strategy:** dependency check.
- **Attempt:** `grep -rn "Tau.Settings.Vault" lib/` confirms
  `lib/tau/settings/vault.ex` is the module's home (first-party).
  Inspected `mix.exs` for any conditional or compile-time
  exclusion of `lib/tau/settings/vault.ex`; none found.
  `lib/tau/providers/anthropic/auth.ex:79–81` already calls
  `Tau.Settings.Vault.resolve/1` unguarded in production code that
  ships today, demonstrating the call pattern is empirically safe.
- **Outcome:** withstood.
- **Action:** none.

### Claim 2: The five adapters Mistral, DeepSeek, Groq, AzureOpenAI, and Custom currently use a `Code.ensure_loaded?(Tau.Settings.Vault)` guard around their vault-key lookup; the solution removes all five.

- **Claim (C):** "Modified `lib/tau/providers/mistral.ex`,
  `lib/tau/providers/deepseek.ex`, `lib/tau/providers/groq.ex` —
  delete private `vault_key/0`; simplify `api_key/0` to call
  `Tau.Providers.Auth.resolve_api_key(...)`" + analogous changes
  for `azure_openai.ex` and `custom.ex` (solution.md L75–86).
- **Grounds (G):** Direct file inspection confirms the guard in
  each:
  - `lib/tau/providers/mistral.ex:94–98` —
    `if Code.ensure_loaded?(Tau.Settings.Vault) do …`
  - `lib/tau/providers/deepseek.ex:101–105` — identical pattern.
  - `lib/tau/providers/groq.ex:94–98` — identical pattern.
  - `lib/tau/providers/azure_openai.ex:152–156` — identical pattern
    keyed to `"AZURE_OPENAI_API_KEY"`.
  - `lib/tau/providers/custom.ex:156–159` — identical pattern keyed
    to `"CUSTOM_API_KEY"`.
- **Warrant (W):** All five sites exhibit the exact pattern claim 1
  shows to be safely simplifiable (unconditional
  `Tau.Settings.Vault.resolve/1`). Mechanical substitution by a
  shared call site removes the duplication without changing
  observable behaviour, satisfying the
  "one place to test, one place to fix" decomplecting goal.
- **Qualifier (Q):** Holds for the five adapters whose primary
  credential is a single string API key resolved by `{:vault,
  "<UPPERCASE_NAME>"}`. Does not extend to Azure's non-key fields
  (`endpoint`, `deployment`, `api_version`) or Custom's `base_url`
  — explicitly out of scope (solution.md L80–83).
- **Rebuttal (R):** If any of the five had a side-effecting `vault_key/0`
  body beyond the simple guard+resolve, replacement would change
  behaviour. Inspection shows all five bodies are exactly the
  two-line `if Code.ensure_loaded?(...) do Tau.Settings.Vault.resolve(...) end`
  — no side effects.
- **Backing (B):** OTP non-negotiable #2 (extensibility seams MUST
  be behaviours; pattern match on atoms and structs — duplicated
  guard logic across five concrete modules is the antipattern this
  invariant exists to forbid).

#### Falsification attempt for claim 2

- **Strategy:** edge-case enumeration over each of the five adapter
  files.
- **Attempt:** Read each `vault_key/0` definition. All five are
  byte-equivalent modulo the env-var name. No side effects, no
  branching besides the guard, no logging. The shared
  `Tau.Providers.Auth.resolve_api_key/3` signature
  `(module, app_env_key_or_module_lookup, vault_name, env_name)` (as
  sketched in proposal-1) cleanly accommodates the only varying
  parameter (the env-var name string). Azure's `vault_key/0` is in a
  larger `resolve_config/0` that also returns endpoint/deployment;
  the solution explicitly carves out only the `:api_key` leg
  (L80–83), so this multi-field shape is non-falsifying.
- **Outcome:** withstood.
- **Action:** none.

### Claim 3: Gemini, currently lacking any vault leg, will gain one via `Tau.Providers.Auth` plus a small adapter-specific `||` fallback that preserves the existing `GEMINI_API_KEY` alias.

- **Claim (C):** "Modified `lib/tau/providers/gemini.ex` — add the
  missing vault leg via
  `Tau.Providers.Auth.resolve_api_key(__MODULE__, "GOOGLE_API_KEY",
  "GOOGLE_API_KEY")`, then keep the existing `GEMINI_API_KEY`
  fallback via a small adapter-specific `||` after the shared call."
  (solution.md L86–89)
- **Grounds (G):** `lib/tau/providers/gemini.ex:172–175`:
  ```
  defp api_key do
    Application.get_env(:tau, __MODULE__, [])[:api_key] ||
      System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY")
  end
  ```
  No vault leg; two env vars. The acceptance criterion (problem.md
  L69–75) requires every production adapter consult vault for its
  primary secret credential.
- **Warrant (W):** A vault leg inserted between `app_env` and
  `system_env` matches the canonical chain in claim 1 and brings
  Gemini into compliance with the acceptance criterion. The
  `GEMINI_API_KEY` second env var is preserved as a post-shared
  fallback — appending one `||` after the shared call retains the
  alias semantics without re-architecting the shared signature.
- **Qualifier (Q):** Holds only if `Tau.Providers.Auth.resolve_api_key/3`
  is implemented with a clean composition point: the resolver must
  return `nil` (not raise) on miss, allowing the caller to chain
  `|| System.get_env("GEMINI_API_KEY")`. Holds only for a single
  vault name `"GOOGLE_API_KEY"`; the solution does not claim the
  vault is also consulted under `"GEMINI_API_KEY"`. **Narrowed
  during validation:** see falsification attempt below.
- **Rebuttal (R):** An operator who has stored credentials in the
  vault under the name `"GEMINI_API_KEY"` (matching the historic
  second env-var alias) will still find them silently ignored —
  the post-shared `||` only consults `System.get_env`, not
  `Tau.Settings.Vault.resolve({:vault, "GEMINI_API_KEY"})`. This
  is a residual silent-inconsistency footgun the acceptance
  criterion was written to eliminate, narrowed to one env-var
  alias on one adapter.
- **Backing (B):** Acceptance criterion in problem.md L69–75 —
  "an operator who configures vault credentials can predict,
  without reading each adapter's source, whether those credentials
  will be honoured." A vault-aware-for-one-alias-only Gemini
  partially defeats predictability for the second alias.

#### Falsification attempt for claim 3

- **Strategy:** edge-case enumeration over the existing Gemini
  env-var aliases.
- **Attempt:** Gemini currently resolves
  `GOOGLE_API_KEY || GEMINI_API_KEY`. The solution wires vault for
  `"GOOGLE_API_KEY"` only. An operator who follows the historic
  practice of storing under `GEMINI_API_KEY` and migrates to the
  vault will lose access — vault will not be consulted under that
  alias.
- **Outcome:** partially falsified. The solution achieves
  vault-consultation for Gemini under the primary `GOOGLE_API_KEY`
  alias but not under the `GEMINI_API_KEY` alias.
- **Action:** narrow claim 3's Qualifier in place (recorded above)
  and add an outstanding doubt for the ADR exception table to
  explicitly document this single-name vault coverage. No revision
  to solution.md required because the acceptance criterion is
  satisfied for the primary name and the residual is recordable
  in the ADR (the artifact the solution already commits to land).

### Claim 4: A new `docs/adr/ADR-00XX-auth-resolution-policy.md` documents the chain plus a per-adapter exception table.

- **Claim (C):** "New file `docs/adr/ADR-00XX-auth-resolution-policy.md`
  — states the four-step chain (`opt → app_env → vault →
  system_env`) and the per-adapter exception table (Anthropic,
  Bedrock, Copilot, Azure non-key fields, Custom `base_url`)."
  (solution.md L90–93)
- **Grounds (G):** The acceptance criterion (problem.md L69–75)
  explicitly requires either "a shared `Tau.Providers.Auth` utility
  or via documented per-adapter policy" — both are listed as
  satisfying alternatives, and the solution provides both. The
  `docs/adr/` directory currently contains 23 ADRs (0000-template
  through 0023, no auth-resolution entry); the next free
  identifier is well-defined.
- **Warrant (W):** Spec-before-code rule (`.claude/rules/spec-before-code.md`)
  obligates a documented record when a coordination-heavy decision
  is made; the per-adapter exception table is precisely the
  artifact that satisfies the "predict without reading each
  adapter's source" clause of the acceptance criterion.
- **Qualifier (Q):** Holds when the ADR is actually written into
  the PR (not deferred to a follow-up). The current `docs/adr/`
  catalog runs 0000–0023; the new ADR would be 0024 (the
  `ADR-00XX` placeholder in the solution must be resolved at PR
  time).
- **Rebuttal (R):** An ADR is a static document; it does not
  mechanically enforce its claims. If a future adapter author
  ignores both the ADR and the shared module, the inconsistency
  reappears. This is the gap claim 5 is designed to close.
- **Backing (B):** `.claude/rules/spec-before-code.md` §"What this
  rule requires" — coordination-heavy components carry a
  documented decision.

#### Falsification attempt for claim 4

- **Strategy:** dependency check.
- **Attempt:** Listed `docs/adr/`; no auth-resolution ADR exists.
  The numbering scheme is monotonic; the next ID is 0024. The
  solution's `00XX` placeholder is conventional but must be
  resolved before merge.
- **Outcome:** withstood.
- **Action:** none, modulo the placeholder resolution at PR time.

### Claim 5: A cross-adapter telemetry test uses `[:tau, :vault, :get]` to assert every listed adapter consults vault during credential resolution.

- **Claim (C):** "New file `test/tau/providers/auth_policy_test.exs`
  — Proposal 4's cross-adapter telemetry test: for each adapter in
  the standard list, assert that `[:tau, :vault, :get]` fires
  during credential resolution." (solution.md L97–99)
- **Grounds (G):** `lib/tau/settings/vault.ex:55–60, 195–205`
  documents and emits `[:tau, :vault, :get]` with metadata
  `%{backend: atom, result: :ok | :not_found | :error, name_hash:
  <truncated sha256>}`. The credential value is never in the
  metadata. An existing test
  (`test/tau/settings/vault_test.exs:137–157`) already asserts the
  event fires correctly, demonstrating the event is observable in
  the test environment.
- **Warrant (W):** A telemetry handler attached in test setup that
  captures every emission of `[:tau, :vault, :get]` provides a
  ground-truth audit of which adapters consulted vault during a
  given test run. Per-adapter assertion that the event fires once
  per `api_key/0` invocation is a mechanical regression gate that
  catches any new adapter (or refactor) that bypasses
  `Tau.Providers.Auth`.
- **Qualifier (Q):** Holds as a fire-only assertion, not a
  return-value assertion (solution.md L166–171 acknowledges this
  explicitly as the test's weakness). The test cannot tell whether
  a vault hit was *used* downstream — only that it was *attempted*.
- **Rebuttal (R):** An adapter could fire the event in a swallowed
  branch (e.g. `_ = Tau.Settings.Vault.resolve(...)` then discard
  the result) and the test would still pass. Solution.md L166–171
  acknowledges this and defers stricter assertion to a follow-up.
- **Backing (B):** OTP non-negotiable #5 (telemetry events MUST
  cover everything user-visible or perf-sensitive). The shared
  Vault telemetry surface is the canonical observation point.

#### Falsification attempt for claim 5

- **Strategy:** integration check (does the boundary exist?).
- **Attempt:** Confirmed `[:tau, :vault, :get]` is emitted from
  `lib/tau/settings/vault.ex:197` via `:telemetry.execute/3`.
  Confirmed `test/tau/settings/vault_test.exs:137–157` already
  exercises the event in test context, so the test surface is
  proven to work. A cross-adapter test merely fans the existing
  pattern over each adapter's `api_key/0` invocation.
- **Outcome:** withstood (modulo the qualifier already noted).
- **Action:** none.

### Claim 6: The `Tau.Provider` behaviour and its `@optional_callbacks` list (including `configure/1`) are left unchanged in this PR.

- **Claim (C):** "The `Tau.Provider` behaviour and its
  `@optional_callbacks` list, including `configure/1`. The
  dead-interface second complecting hypothesis is acknowledged
  but **not** fixed in this PR." (solution.md L102–107)
- **Grounds (G):** `lib/tau/provider.ex:74` declares
  `@callback configure(map()) :: {:ok, map()} | {:error, term()}`
  and `lib/tau/provider.ex:131` includes `configure: 1` in
  `@optional_callbacks`. The solution's "What changes" list does
  not touch `lib/tau/provider.ex`.
- **Warrant (W):** Behavioural surface is a load-bearing public
  contract for every external implementor (out-of-tree adapter
  modules with `@behaviour Tau.Provider`). Promoting `configure/1`
  to mandatory would break every such implementor on next compile.
  Deferring the decision keeps scope tight and preserves
  reversibility.
- **Qualifier (Q):** Holds for this PR. The deferral does not
  resolve the "dead interface surface" hypothesis in problem.md
  §"Complecting hypothesis" item 2 — only the first hypothesis
  (credential priority complecting) is addressed.
- **Rebuttal (R):** Leaving the dead callback misleads new adapter
  authors about where credential logic belongs. The ADR (claim 4)
  partially mitigates this by stating policy in prose; a
  follow-up issue would be appropriate.
- **Backing (B):** OTP non-negotiable #2 (extensibility seams MUST
  be behaviours) — but the corollary is that the behaviour's
  shape MUST NOT be changed gratuitously, because every external
  implementor depends on it.

#### Falsification attempt for claim 6

- **Strategy:** counter-example construction.
- **Attempt:** Inspected `lib/tau/provider.ex:74, 131` to confirm
  `configure/1` is already present and optional. Scanned the
  solution's "What changes" section for any mention of
  `provider.ex` — none. Therefore the behaviour is provably
  unchanged.
- **Outcome:** withstood.
- **Action:** none. (An outstanding doubt is recorded that the
  second complecting hypothesis remains unresolved.)

### Claim 7: Anthropic continues to use its dedicated `Auth` module without modification.

- **Claim (C):** "`lib/tau/providers/anthropic.ex` and
  `lib/tau/providers/anthropic/auth.ex` — Anthropic continues to
  use its dedicated OAuth-capable `Auth` module." (solution.md
  L108–111)
- **Grounds (G):** `lib/tau/providers/anthropic/auth.ex:67–82`
  implements `resolve/1` with a four-step chain
  (`opt → vault(opt) → app_env → vault({:vault, "ANTHROPIC_API_KEY"})`)
  followed by OAuth file fallback. The vault calls are
  unconditional. The OAuth path (D-017) is a first-class
  alternative to API-key auth, with five distinct error variants
  for actionable user messaging (`:no_auth`, `:oauth_expired`,
  `:oauth_missing_scope`, `:oauth_malformed`).
- **Warrant (W):** Anthropic's auth shape is materially distinct
  from the standard API-key adapters — it has two valid auth
  modes (key, OAuth) and a credential-file dependency
  (`~/.claude/.credentials.json`) that the shared resolver
  cannot generically represent. Forcing it into the shared
  signature would either lose the OAuth path or balloon the
  shared signature with mode-discrimination logic that benefits
  only one caller. The ADR exception table is the right artifact
  for the divergence.
- **Qualifier (Q):** Holds while Anthropic continues to support
  both API-key and OAuth modes. If the OAuth mode were dropped,
  Anthropic could fold into the shared resolver — out of scope.
- **Rebuttal (R):** Anthropic's auth module duplicates the
  `app_env → vault` chain logic that the shared module owns. A
  future refactor could parameterise the shared module to host
  Anthropic's first half while keeping the OAuth branch local.
  Out of scope for this PR.
- **Backing (B):** ADR-0016 establishes vault as canonical
  credential custody; the Anthropic OAuth path is the documented
  exception (`docs/spec/SPEC-USER-TURN.md` D-017).

#### Falsification attempt for claim 7

- **Strategy:** counter-example construction.
- **Attempt:** Read `anthropic/auth.ex` end-to-end. The OAuth path
  (`resolve_oauth/1`, lines 84–97) reads `~/.claude/.credentials.json`,
  validates `expires_at` and `scopes`, and returns a five-field
  OAuth map. No generic `Tau.Providers.Auth.resolve_api_key/3`
  signature (string-returning) could accommodate this without
  losing fidelity. The dedicated module is correct.
- **Outcome:** withstood.
- **Action:** none.

### Claim 8: Bedrock and Copilot are explicitly out of the shared chain and recorded as exceptions in the ADR table.

- **Claim (C):** "`lib/tau/providers/bedrock.ex` — the AWS key
  triple plus optional `:aws_credentials` library leg stays in
  place. Bedrock is the ADR's second exception row …
  `lib/tau/providers/copilot/auth.ex` — the two-token OAuth model
  is unchanged; Copilot is documented as the third exception."
  (solution.md L111–118)
- **Grounds (G):** `lib/tau/providers/bedrock.ex:178–200`
  resolves three independent AWS values (access-key, secret-key,
  session-token) and falls back to the `:aws_credentials` Erlang
  library. There is no single primary credential a shared
  resolver could meaningfully target.
  `lib/tau/providers/copilot/auth.ex:1–40` documents the
  two-token model (long-lived OAuth + short-lived API token via
  `TokenStore`) and uses a credential-file path
  (`~/.config/github-copilot/hosts.json`) that has no shared-chain
  analogue.
- **Warrant (W):** Both adapters have credential topologies the
  shared chain provably cannot represent (three-field AWS triple;
  long-lived/short-lived token exchange). The acceptance criterion
  explicitly contemplates this: "via a shared `Tau.Providers.Auth`
  utility OR via documented per-adapter policy" — both Bedrock
  and Copilot belong to the second clause, recorded in the ADR.
- **Qualifier (Q):** Holds while Bedrock's auth remains the AWS
  triple and Copilot remains two-token. The problem.md
  out-of-scope note (L78–84) explicitly excludes both topologies
  from generalisation.
- **Rebuttal (R):** Bedrock currently has no vault integration at
  all. An operator who stores `AWS_ACCESS_KEY_ID` in vault will
  find it silently ignored. The acceptance criterion's
  predictability clause is partially defeated for Bedrock —
  resolved by the ADR exception row, which documents the
  predictability boundary rather than enforces it.
- **Backing (B):** Acceptance criterion's
  "shared OR documented" clause (problem.md L69–75) and
  out-of-scope note (problem.md L78–84). ADR-0016 establishes
  vault as the canonical credential channel; the ADR-00XX (new)
  documents which adapters live outside that channel and why.

#### Falsification attempt for claim 8

- **Strategy:** counter-example construction over the AWS triple.
- **Attempt:** Tried to fit `{access_key_id, secret_access_key,
  session_token}` into the proposed
  `Tau.Providers.Auth.resolve_api_key/3` signature (which returns
  a single string). It cannot — the AWS triple is three
  correlated values, not one secret. A separate
  `resolve_aws_credentials/2` or struct-returning shape would be
  required. The solution correctly carves this out as an
  exception.
- **Outcome:** withstood.
- **Action:** none.

## Cross-claim consistency

Claims 1–3 together describe a "shared resolver covers most adapters,
documented exceptions cover the rest" architecture. Claims 4 and 5
provide the two enforcement layers (operator-readable ADR; mechanical
telemetry test). Claims 6, 7, 8 enumerate the deliberate
non-modifications (`Tau.Provider` behaviour, Anthropic dedicated
module, Bedrock/Copilot exceptions).

A potential tension: Claim 2 says "delete `Code.ensure_loaded?` guards"
because Claim 1 establishes the call is provably safe. But Claim 7
preserves Anthropic's unguarded calls without modification — i.e. the
Anthropic module already operates under Claim 1's warrant in
production today, which is itself the strongest evidence Claim 1 holds.
No genuine tension; the consistency check strengthens Claim 1.

A second potential tension: Claim 3's partial falsification (Gemini
vault-aware only for `GOOGLE_API_KEY`, not `GEMINI_API_KEY`) appears
to weaken Claim 5's "every listed adapter consults vault" assertion.
Resolution: Claim 5's test only verifies the event *fires*; it does
not assert vault is consulted under every historic env-var alias.
The narrowed Qualifier on Claim 3 is internally consistent with
Claim 5's narrower scope.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Shared `Tau.Providers.Auth` with unconditional vault call | dependency check | withstood | none |
| 2 | Remove `Code.ensure_loaded?` guards in five adapters | edge-case enumeration | withstood | none |
| 3 | Gemini gains a vault leg via shared module | edge-case enumeration | partially falsified | narrow Qualifier (recorded in claim 3 Q+R) |
| 4 | ADR documents chain + exception table | dependency check | withstood | resolve `00XX` placeholder at PR time |
| 5 | Cross-adapter telemetry test asserts vault consultation | integration check | withstood | none (qualifier acknowledged in solution) |
| 6 | `Tau.Provider` behaviour unchanged | counter-example construction | withstood | none |
| 7 | Anthropic dedicated `Auth` module unchanged | counter-example construction | withstood | none |
| 8 | Bedrock and Copilot are documented exceptions | counter-example construction | withstood | none |

## Revision required

None. Claim 3 is partially falsified but the falsification narrows the
Qualifier in place rather than requiring a different solution. The
narrowing is documented in claim 3's Q and R fields and surfaces
naturally in the ADR's per-adapter exception table (the artifact
Claim 4 already commits to deliver) — specifically as an explicit row
stating "Gemini: vault consulted under `GOOGLE_API_KEY` only;
`GEMINI_API_KEY` is an env-only alias." The acceptance criterion
("can predict, without reading each adapter's source") is satisfied
once the ADR records this boundary.

- **Target file:** n/a (no revision triggered)
- **Revision kind:** n/a
- **Rationale:** Partial falsification handled in-place via Qualifier
  narrowing and surfaced through the ADR artifact the solution
  already commits to deliver.

## Outstanding doubts

- Claim 3's narrowed Qualifier presumes the ADR row for Gemini
  explicitly enumerates the single vault-name boundary. If the PR
  author omits the explicit row, the predictability gap reappears.
  The reviewer should check the ADR table on PR submission.
- Claim 5's telemetry assertion is fire-only, not use-only
  (solution.md L166–171 acknowledges this). A future adapter could
  consult vault and discard the result, leaving the gate green
  while the credential is silently lost. Strengthening to a
  stub-based "vault value flows into outbound request body"
  assertion is a desirable follow-up but out of scope for this PR.
- The second complecting hypothesis from problem.md (dead
  `configure/1` callback misleads new adapter authors) is
  deliberately left unresolved by this PR. A follow-up issue may
  be warranted but is not required by the acceptance criterion.
- Bedrock's complete absence of vault integration (rebuttal under
  Claim 8) is documented but not closed. An operator who expects
  AWS keys in vault will be silently denied. The ADR records the
  boundary; the operator-facing improvement is out of scope per
  the problem statement.
