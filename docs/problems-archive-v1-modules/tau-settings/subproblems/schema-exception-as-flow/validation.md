---
template_version: 1
template_name: validation
parent_solution: solution.md
parent_problem: problem.md
toulmin_complete: true
falsification_attempted: true
falsification_outcome: partially_falsified — claim/4
revision_triggered: none
---

# Validation: Compile-time string-to-module map replaces try/rescue in binary clause

## Overview

The solution proposes replacing `to_known_module/1`'s `try/rescue ArgumentError`
binary clause with a `case Map.fetch(@known_provider_names, str)` call, where
`@known_provider_names` is a compile-time module attribute derived from
`@known_providers`. Six claims are extracted: (1) the change eliminates `rescue`
from the binary clause; (2) no atom is created at runtime; (3) existing tests
pass without modification; (4) the key-derivation convention is correct for all
current known providers; (5) `mix compile --warnings-as-errors` produces no new
warnings; (6) the public API of `Tau.Settings.Schema` is unchanged. Strategies
applied: edge-case enumeration (claims 1, 2, 5), dependency check (claims 3, 4),
counter-example construction (claim 6). Claim 4 is partially falsified — the
convention works for all current providers but leaves the future-provider case
underdocumented. Qualifier narrowed; no revision required. All other claims
withstood.

---

## Toulmin per claim

### Claim 1: The binary clause of `to_known_module/1` no longer uses `rescue` or `try`

- **Claim (C):** Replace the binary clause body (`try do … rescue ArgumentError`)
  with `case Map.fetch(@known_provider_names, str) do …`, producing no use of
  `rescue` or `try` in the binary clause.
- **Grounds (G):** The current implementation uses `try`/`rescue` at
  `lib/tau/settings/schema.ex:290–296`. The proposed replacement (`case
  Map.fetch(@known_provider_names, str)`) appears verbatim in
  `proposals/proposal-1.md:41–47`. The solution's "What changes" section
  (`solution.md:68–69`) names only these two lines as modified; the atom clause
  at lines 282–288 is explicitly listed as unchanged.
- **Warrant (W):** A `case Map.fetch/2` call raises no exception for a missing
  key — it returns `:error`. Substituting this for a `try`/`rescue` wrapper
  eliminates the exception-as-flow pattern by construction: there is no exception
  to rescue once the call that raised it is removed.
- **Qualifier (Q):** Within the scope of the single binary-clause body at
  `lib/tau/settings/schema.ex:290–296`. No other clause of `to_known_module/1`
  is modified.
- **Rebuttal (R):** If a future refactor collapses both clauses into one, the
  atom clause's `cond` body might re-introduce a coercion call. Not applicable
  to this PR's scope.
- **Backing (B):** `Tau.Settings.Schema` OTP non-negotiables §7 (let it crash;
  no `try/rescue` for ordinary control flow); Elixir official guide on Atoms:
  "prefer `Map.fetch` for user-controlled strings" over `String.to_existing_atom/1`.

#### Falsification attempt for claim 1

- **Strategy:** edge-case enumeration
- **Attempt:** Enumerated all call sites in `to_known_module/1`: (a) the binary
  clause body is the only site using `try/rescue` (`schema.ex:290–296`); (b) the
  atom clause at lines 282–288 uses `cond` and has no exception-raising path;
  (c) the `@known_provider_names` attribute definition itself is a compile-time
  expression using `Map.new/2`, `Atom.to_string/1`, and `String.replace_prefix/3`
  — none of which raise in normal operation. No edge case produces a `rescue` call
  after the replacement.
- **Outcome:** withstood
- **Action:** none

---

### Claim 2: No atom is created at runtime by the binary clause

- **Claim (C):** No atom is created at runtime; `String.to_existing_atom/1` is
  removed; the replacement performs a pure O(1) map lookup.
- **Grounds (G):** The current implementation calls
  `String.to_existing_atom("Elixir." <> str)` at `schema.ex:292`. The proposed
  replacement calls `Map.fetch(@known_provider_names, str)` where
  `@known_provider_names` is frozen into the BEAM module as a literal at compile
  time (`proposals/proposal-1.md:33–39`). `Map.fetch/2` performs no atom
  creation — it pattern-matches on the map's pre-existing atom keys.
- **Warrant (W):** Module attributes evaluated at compile time are inlined as
  literals into the module's bytecode. A map literal in BEAM bytecode does not
  allocate atoms at runtime; its keys already exist as atoms in the atom table at
  compile time. Therefore `Map.fetch(@known_provider_names, str)` at runtime
  touches no new atoms.
- **Qualifier (Q):** Within the binary clause's execution path. The atom clause
  may still coerce atoms via `cond … mod in @known_providers`, but that clause is
  out of scope here.
- **Rebuttal (R):** If `@known_provider_names` were computed lazily (e.g. via a
  `@before_compile` macro that conditionally rebuilds it), the "compile-time
  literal" claim could be weakened. In this case the attribute is declared inline
  (`Map.new(@known_providers, fn mod -> … end)`), so the concern does not apply.
- **Backing (B):** Elixir module attribute documentation (hexdocs.pm/elixir —
  Module attributes): "A module attribute is evaluated at compile time and the
  result is substituted in place."

#### Falsification attempt for claim 2

- **Strategy:** dependency check
- **Attempt:** Verified that `Atom.to_string/1` and `String.replace_prefix/3`
  are used only at attribute-definition time (inside `Map.new/2`), which is a
  compile-time evaluation. At runtime, only `Map.fetch/2` is called. Confirmed
  that `Map.fetch/2` does not intern atoms by inspecting its type signature
  (`Map.fetch(map(), key()) :: {:ok, value()} | :error`) and the Elixir stdlib
  source — it is a BIF with no atom-creation side effect.
- **Outcome:** withstood
- **Action:** none

---

### Claim 3: Existing `schema_test.exs` tests pass without modification

- **Claim (C):** `test/tau/settings/schema_test.exs` tests for
  `resolve_fallback_chains/1` all continue to pass; no test changes are required.
- **Grounds (G):** `test/tau/settings/schema_test.exs:69–94` exercises two paths:
  (a) "resolves string-keyed chains to atom modules from the known set" (line 69)
  uses `"Tau.Providers.Anthropic"`, `"Tau.Providers.OpenAI.Chat"`,
  `"Tau.Providers.Gemini"` as string keys; (b) "rejects unknown providers
  fail-closed" (line 88) uses `"NotARealProvider"` and expects `{:error,
  {:unknown_provider, "NotARealProvider"}}`. The map-fetch replacement returns
  `{:ok, mod}` for known strings and `{:error, {:unknown_provider, str}}` for
  unknown — identical signatures to the current rescue-based implementation.
- **Warrant (W):** A function whose input/output contract is identical to its
  predecessor's — same accepted values, same rejected values, same tagged-tuple
  shape — passes the same test suite by definition, provided no test inspects
  internal implementation details (e.g. stack traces or rescue paths, which none
  of these tests do).
- **Qualifier (Q):** For the two `resolve_fallback_chains/1` tests in scope. If
  there were tests inspecting stack-trace content or testing for a specific
  `ArgumentError` being raised, the claim would not hold; no such tests exist in
  the cited file.
- **Rebuttal (R):** If `mix test` reveals compilation warnings-as-errors or
  dialyzer type errors in the revised module (e.g. due to a type mismatch in
  `@known_provider_names`), the suite might fail at the compilation step rather
  than the assertion step. This is addressed by claim 5.
- **Backing (B):** `problem.md` acceptance criterion: "the existing `schema_test.exs`
  tests for `resolve_fallback_chains/1` all continue to pass."

#### Falsification attempt for claim 3

- **Strategy:** dependency check
- **Attempt:** Verified the test's string inputs (`"Tau.Providers.Anthropic"`,
  `"Tau.Providers.OpenAI.Chat"`, `"Tau.Providers.Gemini"`) against the
  key-derivation formula `Atom.to_string(mod) |> String.replace_prefix("Elixir.", "")`:
  - `Tau.Providers.Anthropic` → `"Elixir.Tau.Providers.Anthropic"` →
    `"Tau.Providers.Anthropic"` ✓
  - `Tau.Providers.OpenAI.Chat` → `"Elixir.Tau.Providers.OpenAI.Chat"` →
    `"Tau.Providers.OpenAI.Chat"` ✓
  - `Tau.Providers.Gemini` → `"Elixir.Tau.Providers.Gemini"` →
    `"Tau.Providers.Gemini"` ✓
  - `"NotARealProvider"` — not in map → `:error` → `{:error, {:unknown_provider,
    "NotARealProvider"}}` ✓
  All four cases produce the same result as the current implementation.
- **Outcome:** withstood
- **Action:** none

---

### Claim 4: The key-derivation convention (`Atom.to_string |> String.replace_prefix("Elixir.", "")`) correctly covers all current known providers

- **Claim (C):** The `@known_provider_names` map, built by stripping the
  `"Elixir."` prefix from each provider atom's string form, produces keys that
  match what callers write in `.tau/settings.json` for all current providers in
  `@known_providers`.
- **Grounds (G):** `@known_providers` at `schema.ex:47–54` lists six modules:
  `Tau.Providers.Anthropic`, `Tau.Providers.OpenAI.Chat`,
  `Tau.Providers.OpenAI.Responses`, `Tau.Providers.Gemini`,
  `Tau.Providers.Bedrock`, `Tau.Providers.Replay`. Tests at
  `schema_test.exs:73` use `"Tau.Providers.Anthropic"`, `"Tau.Providers.OpenAI.Chat"`,
  `"Tau.Providers.Gemini"` as the string keys that callers write, which match the
  derivation output exactly (see Claim 3 falsification). No documentation or test
  in the codebase uses a short-form name (e.g. `"Anthropic"` alone) for these
  providers. The `Open Questions` in `solution.md:91–97` explicitly raises this
  concern but concludes behaviour is preserved vs. the current implementation.
- **Warrant (W):** A compile-time map whose key-derivation formula matches the
  string format exercised by all existing tests of the relevant function is
  consistent with those tests. Absence of any test or documentation using an
  alternative string format is evidence (though not proof) that no caller uses
  such a format today.
- **Qualifier (Q):** For the six providers currently in `@known_providers` and
  the string format used in existing tests and codebase documentation. Does NOT
  extend to hypothetical future providers with atypical namespacing, or to
  user-facing documentation outside the codebase that may describe short-form
  names.
- **Rebuttal (R):** External documentation (README, website, provider-specific
  docs under `docs/providers/`) could instruct users to write short-form provider
  names (e.g. `"Anthropic"`) in `.tau/settings.json`. If such documentation
  exists, the new implementation would silently reject those names (same as the
  old implementation, but the key-derivation convention would now be load-bearing
  and undocumented). The `solution.md` open question acknowledges this.
- **Backing (B):** `solution.md:91–97` (Open questions, key-derivation
  convention); `proposals/proposal-1.md:70–75` (Weaknesses, key convention
  undocumented); `schema_test.exs:73` (observed format).

#### Falsification attempt for claim 4

- **Strategy:** edge-case enumeration
- **Attempt:** Scanned `docs/providers/` for provider name strings users would
  write in `.tau/settings.json`. Found `docs/providers/azure_openai.md`,
  `docs/providers/deepseek.md`, `docs/providers/mistral.md` — none of these
  providers are in `@known_providers` (they are not yet integrated), so their
  name format does not affect the current claim. No file in `docs/` or `test/`
  uses a short-form name (e.g. `"Anthropic"`) as a settings string. The
  `proposals/proposal-1.md` sketch comment explicitly warns about this case but
  concludes the convention is correct for the current set. The claim holds for
  all six current providers but the qualifier must be narrowed: the convention
  is unverified for providers added in the future without a corresponding test
  update.
- **Outcome:** partially falsified — the convention is correct for all six
  current providers but the claim "correctly covers all current known providers"
  is only safe so long as no external documentation directs users to an
  alternative string format. The qualifier is narrowed accordingly.
- **Action:** Narrow qualifier to "for all six providers in `@known_providers`
  at `schema.ex:47–54`, as exercised by existing tests; excludes future providers
  and any external documentation using alternative name formats." No solution
  revision required; the `solution.md` Open Questions section already
  acknowledges the risk.

---

### Claim 5: `mix compile --warnings-as-errors` produces no new warnings

- **Claim (C):** The change produces no new compiler warnings; `mix compile
  --warnings-as-errors` passes.
- **Grounds (G):** The proposed `@known_provider_names` attribute uses
  `Map.new/2`, `Atom.to_string/1`, and `String.replace_prefix/3` — all standard
  library functions with well-defined types. The binary-clause replacement uses
  `Map.fetch/2` returning `{:ok, value} | :error` and a two-branch `case` — a
  type-safe pattern. No new dependency is introduced. The solution notes
  `mix compile --warnings-as-errors` as a verification step
  (`solution.md:86–87`).
- **Warrant (W):** A change that uses only standard library functions with stable
  type signatures in a `case` pattern that is exhaustive (both `{:ok, mod}` and
  `:error` are handled) produces no pattern-match or type warnings under the
  Elixir compiler.
- **Qualifier (Q):** Absent any pre-existing unresolved warnings in the module
  that are currently suppressed. The claim is about *new* warnings introduced by
  this specific change.
- **Rebuttal (R):** If dialyzer's type specification for `@known_provider_names`
  infers a different key type than `String.t()`, a downstream warning in the
  clause head `when is_binary(str)` could surface. This is unlikely given the
  derivation is homogeneous (all keys are `String.replace_prefix/3` results).
- **Backing (B):** Elixir compiler documentation on exhaustive `case` (no
  unreachable-clause warning for a two-branch `case Map.fetch/2`); `problem.md`
  acceptance criterion: "`mix compile --warnings-as-errors` produces no new
  warnings."

#### Falsification attempt for claim 5

- **Strategy:** type-level check
- **Attempt:** Mentally traced the type of `@known_provider_names`:
  `Map.new([@known_providers], fn mod -> {String.t(), module()} end)` → `%{String.t() => module()}`.
  The call `Map.fetch(@known_provider_names, str)` where `str :: String.t()` is
  type-safe. The `case` branches `{:ok, mod}` and `:error` are the complete
  return type of `Map.fetch/2`. The function's return type `{:ok, module()} |
  {:error, {:unknown_provider, String.t()}}` is unchanged from the current
  implementation. No unused-variable, pattern-unreachable, or type-mismatch
  warnings are produced by this change.
- **Outcome:** withstood
- **Action:** none

---

### Claim 6: The public API of `Tau.Settings.Schema` is unchanged

- **Claim (C):** No new public functions are added; no existing public function
  signatures are changed; the module's API surface is identical before and after
  the edit.
- **Grounds (G):** `solution.md:72` states "The public API of
  `Tau.Settings.Schema` — no new public functions." The change modifies only the
  private function `to_known_module/1` (`defp`, lines 282–296) and adds a module
  attribute `@known_provider_names`. Neither affects the module's public exports.
  `resolve_fallback_chains/1`, `known_providers/0`, `json_schema/0`, and all
  other public functions are listed as out of scope in the "What does not change"
  section (`solution.md:72–77`).
- **Warrant (W):** A `defp` function is private; adding or modifying a `defp`
  does not alter the module's exported function set. Module attributes are not
  exported. Therefore no change to `defp to_known_module/1` or a new module
  attribute can alter the public API.
- **Qualifier (Q):** Q: none — universal. The Elixir visibility model is binary:
  `def` is public, `defp` is private. There is no conditional visibility.
- **Rebuttal (R):** None. Module attribute additions and `defp` modifications
  are categorically invisible to external callers in Elixir.
- **Backing (B):** Elixir language reference: "Private functions defined with
  `defp` macros are only accessible to the module in which they are defined"
  (hexdocs.pm/elixir — Kernel.defp/2).

#### Falsification attempt for claim 6

- **Strategy:** counter-example construction
- **Attempt:** Attempted to construct a scenario where modifying `defp
  to_known_module/1` or adding `@known_provider_names` alters the public API.
  No such scenario exists: (a) `@module_attribute` is not exported; (b) `defp`
  is not exported; (c) the return type of the public callers
  (`resolve_fallback_chains/1`) is unchanged — it returns `{:ok, map()} | {:error,
  {:unknown_provider, binary()}}` in both before and after states. Cannot
  construct a counter-example.
- **Outcome:** withstood
- **Action:** none

---

## Cross-claim consistency

Claims 1–6 are mutually consistent. The core dependency chain is: Claim 2
(no atom creation) depends on Claim 1 (exception path removed) — both are
satisfied simultaneously by the same substitution. Claim 3 (tests pass) depends
on Claim 4 (key derivation correct) — verified by the dependency check on
claim 3. Claim 5 (no new warnings) is independent of 1–4. Claim 6 (public
API unchanged) is independent of all others.

One tension was considered: Claim 4's partial falsification (key convention is
underdocumented for future providers) might be thought to undermine Claim 3
(tests pass). It does not — the tests pass precisely because the current
providers' key formats are correct; the underdocumented risk is forward-looking
only. The qualifier narrowing on Claim 4 bounds the claim correctly without
weakening Claim 3.

---

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | `rescue`/`try` eliminated from binary clause | edge-case enumeration | withstood | none |
| 2 | No atom created at runtime | dependency check | withstood | none |
| 3 | Existing tests pass without modification | dependency check | withstood | none |
| 4 | Key-derivation correct for all current providers | edge-case enumeration | partially falsified | narrow qualifier; no revision |
| 5 | No new compiler warnings | type-level check | withstood | none |
| 6 | Public API unchanged | counter-example construction | withstood | none |

---

## Revision required

No revision required. Claim 4 is partially falsified; its qualifier is narrowed
to the six current providers as exercised by existing tests, with the exclusion
of future providers and external documentation. The `solution.md` Open Questions
section already captures this risk explicitly. No claim is fully falsified.

---

## Outstanding doubts

1. **External documentation format.** No file under `docs/providers/` or in
   external user-facing documentation was found using short-form provider names
   (e.g. `"Anthropic"`) in settings. However, the search was limited to the
   repository. If user-facing documentation outside the repo (website, README
   rendered on GitHub/Codeberg) instructs users to write short-form names, the
   implementation would silently reject those inputs — identically to the current
   implementation, but the key-derivation convention would become the authoritative
   source of truth without being documented as such. The `solution.md` open
   question recommends verifying this before landing.

2. **`mix test` verification.** The claim that existing tests pass is derived by
   manual inspection of the key-derivation formula against the test inputs. It
   was not verified by running `mix test` in the worktree (read-only validation
   scope). The manual derivation is unambiguous for all six current providers,
   but a compilation edge case (e.g. an existing unresolved warning turned into
   an error by a toolchain version mismatch) could cause an unexpected failure.
