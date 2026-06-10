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

# Validation: Extract `Tau.Providers.Catalog` as single source of truth

## Overview

The solution makes eight checkable propositions: (1) introduce a pure
`Tau.Providers.Catalog` data module as the single registry, (2) delete
`Init.@providers` and `Logout.@credential_map` literal copies and derive
them from `Catalog` at compile time, (3) fix the `List.first` truncation
by persisting all selections under a new `"enabled_providers"` array
key while retaining `"provider"` (singular) for backwards compatibility,
(4) `"enabled_providers"` (not `"providers"`) is the correct key name
because the existing `"providers"` is an ADR-0012 object and the top
level uses `additionalProperties: false`, (5) the schema's
`@known_top_level_keys` is derived from `Map.keys(properties)` at
compile time so the new entry is picked up automatically, (6) `Logout`
behaviour is preserved because the derived `@credential_map` values
match the literal it replaces, (7) the change satisfies OTP
non-negotiables #3 (no GenServer for stateless logic) and #8 (pure
functions default), and (8) the Bedrock round-trip (init → vault →
logout) is correctly closed because `Catalog.by_key(:bedrock).env_var`
becomes `"AWS_SECRET_ACCESS_KEY"` — the same key `Logout` removes.

Per-claim strategy was a mix of dependency check, type-level check,
edge-case enumeration, and counter-example construction. Seven claims
withstood; one (claim 4 / claim 8 interaction) is partially falsified
on Bedrock semantics — see "Outstanding doubts".

## Toulmin per claim

The MITRE empirical study on Toulmin formalism found that "participants
found it difficult to generate Toulmin structures, and their structures
varied greatly even though they started with the same content"
(https://www.mitre.org/news-insights/publication/empirical-evaluation-structured-argumentation-using-toulmin-argument).
This validation enforces all six components explicitly per claim.

### Claim 1: `Tau.Providers.Catalog` becomes the single source of truth for provider identity → vault env var → settings string key.

- **Claim (C):** "Introduce `lib/tau/providers/catalog.ex` — a pure
  compile-time data module — as the single authoritative registry
  mapping each provider atom to its label, vault credential name, and
  settings string key. Delete `Init.@providers` and
  `Logout.@credential_map`; both modules derive their provider knowledge
  from `Catalog` at compile time." (solution.md §Recommendation)
- **Grounds (G):** `lib/tau/cli/init.ex:59–65` defines `@providers` as
  a literal of five `%{key:, label:, env:}` entries. `lib/tau/commands/
  builtin/logout.ex:38–43` defines `@credential_map` as a literal of
  four `string => env_var` entries. These are the only two literals in
  the codebase that bind a provider identity to a vault credential name
  (`grep -rn "AWS_SECRET_ACCESS_KEY\|AWS_ACCESS_KEY_ID" lib/` returns
  only these two plus `bedrock.ex:182–185`, which is a *reader* of
  `System.get_env`, not a writer of the mapping). Centralising both
  into a single literal removes the only known drift surface.
- **Warrant (W):** Hickey's "complect" principle: identity (provider
  atom) and policy (credential name, label, string key) are independent
  facts and should be stored exactly once. Tau OTP non-negotiable #2
  (extensibility seams are behaviours; pattern-match on atoms and
  structs) reinforces that the catalogue is the natural lookup table.
- **Qualifier (Q):** Holds for the *current* set of two literal
  copies. Does not address `Tau.Settings.Schema.@known_providers`
  (`schema.ex:47–54`), which is a third, structurally distinct
  registry that the solution explicitly leaves out of scope (see
  solution.md §Open questions, third bullet).
- **Rebuttal (R):** A future code path that adds a third literal copy
  (e.g. an integration test that hand-rolls the same map) would
  re-introduce drift; the property test in
  `test/tau/providers/catalog_test.exs` only asserts internal
  consistency of `Catalog`, not exclusivity of `Catalog` as the
  registry.
- **Backing (B):** Hickey, "Simple Made Easy" (2011): independent
  facts should not be braided. CLAUDE.md → `otp-non-negotiables.md`
  §1–2.

#### Falsification attempt for claim 1

- **Strategy:** Dependency check (does the codebase truly contain
  only two such literals today, so the extraction *can* be the sole
  source of truth?) + edge-case enumeration (other readers of the
  provider→env mapping).
- **Attempt:** Ran `grep -rn "AWS_SECRET_ACCESS_KEY\|AWS_ACCESS_KEY_ID"
  lib/`, `grep -rn "ANTHROPIC_API_KEY\|OPENAI_API_KEY\|GEMINI_API_KEY"
  lib/`, and `grep -rn "@providers\|@credential_map" lib/`. The hits
  outside `init.ex` and `logout.ex` are `bedrock.ex` (reads env), and
  the moduledoc tables (documentation, not code).
- **Outcome:** withstood. Two literal copies; centralisation removes
  both.
- **Action:** none.

### Claim 2: `Init.@providers` and `Logout.@credential_map` are deleted and replaced by compile-time derivation from `Catalog`.

- **Claim (C):** "Delete `@providers` module attribute … `alias
  Tau.Providers.Catalog`; replace all `@providers` references with
  `Catalog.all()`" (solution.md §What changes) and "Delete
  `@credential_map` literal … add `@credential_map
  Catalog.credential_map()` (compile-time derivation — no runtime
  cost, no behaviour change)".
- **Grounds (G):** `@providers` is referenced in `init.ex` at lines
  137, 205, 218, 231, 232, 250 (verified by reading the full file).
  `@credential_map` is referenced in `logout.ex` at lines 57, 60, 61,
  65. All references are pure-data lookups (`length/1`, `Enum.at/2`,
  `Enum.with_index/2`, `Map.has_key?/2`, `Map.keys/1`) that work
  equivalently against the value returned by `Catalog.all/0` or
  `Catalog.credential_map/0`.
- **Warrant (W):** A `@module_attribute` bound to a function call at
  compile time evaluates that call once during compilation and freezes
  the result into the module's BEAM file (Elixir Module Attributes
  reference). Therefore `@credential_map Catalog.credential_map()`
  produces a literal identical to the deleted `@credential_map %{…}`
  if and only if `Catalog.credential_map/0` returns the same map.
- **Qualifier (Q):** Holds iff `Catalog.credential_map/0` is a pure
  function (no I/O, no `System.get_env`, no compile-time
  configuration). The solution sketches it as `@entries`-derived,
  which satisfies purity.
- **Rebuttal (R):** If `Catalog` is loaded after either consumer
  module at compile time (i.e. compilation order inversion), the
  `@credential_map Catalog.credential_map()` line would fail with
  `UndefinedFunctionError`. Elixir's compiler handles this via
  dependency tracking; an explicit `require Tau.Providers.Catalog`
  guarantees ordering. The solution does not name `require` but
  `alias` plus the function call in a module attribute is sufficient
  to register the dependency in standard projects.
- **Backing (B):** Elixir documentation — Module Attributes:
  "Module attributes can also be used as temporary storage to be used
  during compilation". `mix compile --warnings-as-errors` is the
  project's gate (CLAUDE.md → project lints).

#### Falsification attempt for claim 2

- **Strategy:** Type-level check + counter-example construction.
- **Attempt:** Mentally substituted `@providers` with `Catalog.all()`
  at each call site in `init.ex`. Every call site uses operations
  defined on `Enum`/`Map`/`length` — they accept any list/map. For
  `@credential_map`, the four call sites all read the map by key or
  enumerate keys; identical to current behaviour iff `Catalog`'s map
  has the same shape. The proposal's sketch (`%{key: …, env: …,
  string_key: …}`) is a superset of `%{key: …, env: …, label: …}`,
  so existing reads remain valid.
- **Outcome:** withstood.
- **Action:** none. (The implementer note about purity stands; gating
  test must check `Catalog.credential_map/0` is invoked at compile
  time, not runtime.)

### Claim 3: Persisting all N selections under `"enabled_providers"` while keeping `"provider"` singular satisfies the AC for N > 1.

- **Claim (C):** "Fix the `List.first` truncation by persisting all
  selected provider strings under a new `"enabled_providers"` array
  key in `settings.local.json` (with `"provider"` retaining the first
  selection for backwards compatibility)".
- **Grounds (G):** `lib/tau/cli/init.ex:153` is the truncation site
  (verified verbatim). `provider_selection/1` (line 201–221) correctly
  returns a list of all selected keys. Replacing `Map.put("provider",
  providers |> List.first() |> provider_string())` with both that put
  and `Map.put("enabled_providers", Enum.map(providers, &Catalog.by_
  key(&1).string_key))` writes all N selections. The AC ("the written
  `settings.local.json` reflects all N selections") is satisfied: all
  N selections appear under `enabled_providers`.
- **Warrant (W):** Acceptance is a behavioural property of the
  written JSON file: an external observer (`Jason.decode!` over the
  file) sees N selected provider strings. A test of the form
  `assert decoded["enabled_providers"] == ["anthropic", "openai_chat"]`
  for a two-select input falsifies the bug-as-written.
- **Qualifier (Q):** Holds when the schema admits the new key (claim
  4) and when `Catalog.by_key(k)` returns a non-nil entry for every
  selected key (covered by solution.md §Open questions bullet 1,
  delegated to implementer).
- **Rebuttal (R):** If a downstream reader of `settings.local.json`
  expects "the list of enabled providers" under the singular
  `"provider"` key as a comma-joined string, this change would not
  satisfy it. Grep shows no such reader: the only `"provider"` key
  consumers are TUI bootstrap (`lib/tau/tui/app/bootstrap.ex:33`),
  events (`events.ex:312`), and view (`view.ex:122`), all of which
  read a *single* provider atom. Compatibility is preserved.
- **Backing (B):** problem.md §Acceptance criterion ("the written
  `settings.local.json` reflects all N selections"). Hickey on data:
  the persisted shape is the contract; reading code adapts.

#### Falsification attempt for claim 3

- **Strategy:** Counter-example construction over the AC's input
  space.
- **Attempt:** Constructed N = 2 case (user selects indices "1,2"):
  `provider_selection/1` returns `[:anthropic, :openai_chat]`. New
  `drive_flow/1` writes `%{"provider" => "anthropic",
  "enabled_providers" => ["anthropic", "openai_chat"]}`. After
  `Jason.encode!`, both keys appear in the JSON; `enabled_providers`
  reflects both selections. AC satisfied. Constructed N = 5 (all
  providers): same shape, list of length 5. AC satisfied. Constructed
  N = 0 (empty input → defaults to first; per parse_provider_indices/
  1): list of length 1 with the default; AC vacuously satisfied
  (N > 1 not triggered).
- **Outcome:** withstood.
- **Action:** none.

### Claim 4: `"enabled_providers"` (not `"providers"`) is the correct top-level key because `"providers"` is already an ADR-0012 object and the top level uses `additionalProperties: false`.

- **Claim (C):** "The key name is deliberately `"enabled_providers"`,
  not `"providers"`: the latter is already defined at
  `lib/tau/settings/schema.ex:121` as an OBJECT for ADR-0012
  per-provider fallback chains, and the schema enforces
  `additionalProperties: false` at the top level, so reusing
  `"providers"` would be both a type-shape collision (array vs object)
  and a semantic collision (enablement set vs fallback-chain config)."
- **Grounds (G):** `schema.ex:66` reads
  `"additionalProperties" => false` (verified). `schema.ex:121` reads
  `"providers" => %{"type" => "object", "additionalProperties" =>
  true, "properties" => %{"fallback_chains" => …}}` (verified).
  `schema.ex:253` shows the *consumer*:
  `providers = Map.get(settings, :providers) || Map.get(settings,
  "providers") || %{}` followed by
  `Map.get(providers, :fallback_chains) || …` — exclusively object
  semantics. `docs/adr/0012-provider-fallback-is-fsm-internal-retry.md`
  exists. Reusing `"providers"` as an array would (a) double-define a
  key in the schema literal (Elixir map-literal duplicate-key warning
  → `--warnings-as-errors` failure) or (b) silently overwrite the
  ADR-0012 entry, breaking `resolve_fallback_chains/1`.
- **Warrant (W):** A JSON Schema with `additionalProperties: false`
  rejects any top-level key not enumerated in `properties`. Two
  entries for the same key in an Elixir map literal raise a
  compile-time warning. Two entries with conflicting `type`
  declarations (object vs array) cannot both be valid simultaneously.
- **Qualifier (Q):** none — universal across the current schema and
  validator pinning (ex_json_schema ~> 0.10, Draft 7).
- **Rebuttal (R):** If `additionalProperties: false` were relaxed at
  the top level, the array could in principle live under a different
  shape, but the rebuttal does not apply because the schema as-pinned
  enforces it.
- **Backing (B):** JSON Schema Draft 7 §6.5.6
  (additionalProperties); Elixir Map module documentation on literal
  duplicate keys; `docs/adr/0012-provider-fallback-is-fsm-internal-
  retry.md`.

#### Falsification attempt for claim 4

- **Strategy:** Dependency check (does `"providers"` already exist as
  claimed?) + counter-example construction (could `"providers"` be
  safely reused?).
- **Attempt:** Verified line 121 of `schema.ex` defines `"providers"`
  as an object with `fallback_chains`. Verified line 66 sets
  `additionalProperties: false`. Verified line 253's consumer treats
  `settings["providers"]` exclusively as an object with `:atom_keys`
  or `"string_keys"` mapping to `fallback_chains`. Attempted to
  imagine a structurally compatible reuse: even a union shape
  `["array", "object"]` would break `resolve_fallback_chains/1`,
  which assumes `Map.get(providers, :fallback_chains)` — calling
  `Map.get/2` on a list raises. The reuse is infeasible.
- **Outcome:** withstood.
- **Action:** none. NB the falsification ALSO ruled out the only
  obvious alternative (typed union); the chosen new-key approach
  appears unique.

### Claim 5: `@known_top_level_keys` automatically picks up the new entry, so no separate registration step is needed.

- **Claim (C):** "`@known_top_level_keys` is derived from
  `Map.keys(properties)` at compile time, so the new entry is picked
  up automatically."
- **Grounds (G):** `schema.ex:216` reads
  `@known_top_level_keys @schema |> Map.fetch!("properties") |>
  Map.keys() |> Enum.sort()`. Adding `"enabled_providers"` to
  `"properties"` causes `Map.keys/1` to include it; sort is stable;
  `@known_top_level_keys` ends up with the new entry without further
  edits.
- **Warrant (W):** Module attribute definitions are evaluated
  exactly once at compile time, after the lexically preceding
  attributes are bound; `Map.keys/1` is a pure function over the
  attribute's value.
- **Qualifier (Q):** Holds for `mix compile`; does not address
  `Tau.Settings.Loader`'s `list_keys/0` function (line 88) which is a
  *separately maintained* list used for cascade merging — see
  "Outstanding doubts" and Claim 8.
- **Rebuttal (R):** None at this layer.
- **Backing (B):** Elixir Module Attributes documentation; the
  schema's own moduledoc §"additionalProperties policy".

#### Falsification attempt for claim 5

- **Strategy:** Type-level check.
- **Attempt:** Symbolically reduced
  `@schema |> Map.fetch!("properties") |> Map.keys() |> Enum.sort()`
  with `"enabled_providers"` added to `properties`. Result is the
  current sorted list with `"enabled_providers"` inserted in sort
  order. No dependency on the entry's value type.
- **Outcome:** withstood.
- **Action:** none.

### Claim 6: `Logout`'s observable behaviour is unchanged.

- **Claim (C):** "`Logout.run/2` body logic — `@credential_map` is now
  compile-time derived from `Catalog`; the map value and all pattern
  matches are identical."
- **Grounds (G):** `logout.ex:38–43` shows the literal map.
  `Catalog.credential_map/0` is sketched to return the same shape
  (`%{string => env_var}`) with the same four entries (anthropic,
  openai, gemini, bedrock). Every other line of `Logout.run/2`
  (lines 52–88) is unchanged.
- **Warrant (W):** Two `@credential_map` bindings produce
  observationally identical modules iff the map values are equal as
  Elixir terms.
- **Qualifier (Q):** Holds iff `Catalog`'s string keys exactly match
  `{"anthropic", "openai", "gemini", "bedrock"}`. Note: the wizard's
  `provider_string/1` (init.ex:505–509) emits *five* strings:
  `"anthropic", "openai_chat", "openai_responses", "gemini",
  "bedrock"`. The current `@credential_map` collapses both
  `:openai_chat` and `:openai_responses` to a single `"openai"` key.
  The solution's `string_key` field per provider must therefore
  reconcile this asymmetry: the wizard-side string keys are NOT the
  same as the logout-side credential-map keys. The solution glosses
  this — see "Outstanding doubts".
- **Rebuttal (R):** If `Catalog.credential_map/0` introduces a new
  key (e.g. splits `"openai"` into `"openai_chat"`/`"openai_responses"`
  to match the wizard's `string_key`), then existing `/logout openai`
  invocations would break.
- **Backing (B):** the moduledoc table at `logout.ex:14–21` is the
  user-facing API contract; preserving it is a compatibility
  requirement.

#### Falsification attempt for claim 6

- **Strategy:** Counter-example construction over the public API
  (`/logout <provider>`).
- **Attempt:** Constructed call `/logout openai`: current code
  resolves to `OPENAI_API_KEY` via the literal map. Constructed call
  `/logout bedrock`: resolves to `AWS_SECRET_ACCESS_KEY` (the
  documented behaviour). After extraction, *iff* `Catalog`'s entries
  include `string_key: "openai"` for one entry and
  `string_key: "bedrock"` for the bedrock entry, the derived map
  produces identical lookups. But the wizard's `provider_string/1`
  emits `"openai_chat"`/`"openai_responses"` for the two openai
  providers — a 1:1 with the atoms but a 2:1 with the credential. The
  catalog must therefore distinguish two concepts: a *settings
  string_key* (wizard-side) and a *logout alias* (logout-side). The
  solution sketches a single `string_key` field per entry; it does
  not name a separate alias. This is an under-specification, not a
  falsification, because the implementer can reconcile either by
  (a) giving openai_chat and openai_responses the same string_key
  ("openai"), losing wizard fidelity, or (b) adding a separate
  `logout_alias` field. Either path preserves Logout behaviour; the
  solution leaves the choice open.
- **Outcome:** withstood at the claim's stated scope (Logout
  behaviour preserved) but the catalog field set is
  under-specified. Implementer must resolve.
- **Action:** none for the validator; flag as "Outstanding doubt 1"
  for the implementer.

### Claim 7: The change satisfies OTP non-negotiables #3 (no GenServer for stateless logic) and #8 (pure functions default).

- **Claim (C):** "The new module is pure data (no GenServer, no ETS,
  no runtime state), consistent with OTP non-negotiables #3 and #8."
- **Grounds (G):** The proposed module is described as a pure
  compile-time data module exposing `all/0`, `by_key/1`,
  `by_string_key/1`, `credential_map/0` — all pure functions over a
  `@entries` literal.
- **Warrant (W):** A module containing only `@entries` (a literal
  list of maps) and pure functions over it is, by inspection, both
  stateless and process-free.
- **Qualifier (Q):** none — universal for the proposed module shape.
- **Rebuttal (R):** None at the design layer; implementer could
  inadvertently introduce `Application.get_env/2` reads if the
  catalog is ever made configurable, which would violate
  non-negotiable #1.
- **Backing (B):** `.claude/rules/otp-non-negotiables.md` items #3
  and #8.

#### Falsification attempt for claim 7

- **Strategy:** Type-level check against `otp-non-negotiables.md`.
- **Attempt:** Item #1 (stateful subsystems supervised): N/A — the
  module is stateless. #2 (extensibility seams as behaviours): N/A —
  the catalog is data, not a seam. #3 (no GenServer for stateless
  logic): satisfied. #4 (cross-process events via PubSub): N/A.
  #5 (telemetry): N/A — pure data module. #6 (properties before
  examples): satisfied by the proposed `catalog_test.exs` property
  tests. #7 (let it crash): N/A. #8 (pure default): satisfied.
- **Outcome:** withstood.
- **Action:** none.

### Claim 8: The Bedrock credential round-trip (init → vault → logout) is closed by `Catalog.by_key(:bedrock).env_var = "AWS_SECRET_ACCESS_KEY"`.

- **Claim (C):** "Schema acceptance is verifiable by … the Bedrock
  credential round-trip (init → vault → logout) is verifiable by
  tracing `Catalog.by_key(:bedrock).env_var` →
  `"AWS_SECRET_ACCESS_KEY"` → `Logout.@credential_map["bedrock"]`."
  (solution.md §Migration sketch step 5)
- **Grounds (G):** problem.md states init currently uses
  `AWS_ACCESS_KEY_ID` and logout uses `AWS_SECRET_ACCESS_KEY`. The
  solution proposes a single source of truth; the implementer must
  pick *one* env var name for Bedrock in `Catalog`. The solution
  implies the choice is `AWS_SECRET_ACCESS_KEY` (to match logout's
  current behaviour), which means the wizard would prompt for the
  *secret* under the env name `AWS_SECRET_ACCESS_KEY`.
- **Warrant (W):** A round-trip is closed iff
  `init.store_credential` writes the same vault key that
  `logout.delete` reads.
- **Qualifier (Q):** Holds for the secret-access-key half of AWS
  SigV4 credentials. Bedrock authentication *requires both*
  `AWS_ACCESS_KEY_ID` AND `AWS_SECRET_ACCESS_KEY` (verified at
  `lib/tau/providers/bedrock.ex:182–185`: the provider reads both
  via `System.get_env`). The wizard prompting for a single env var
  named `AWS_SECRET_ACCESS_KEY` does not provision the access-key-id
  half. Bedrock auth will fail at request time unless the user has
  exported `AWS_ACCESS_KEY_ID` by some other means (shell rc,
  `~/.aws/credentials`, IMDS).
- **Rebuttal (R):** The problem statement frames the bug as
  "init/logout disagree on the key name"; a fix that aligns them on
  *one* key does close that bug per the AC. The deeper question —
  "should the wizard prompt for both AWS credentials, or for a
  symbolic 'AWS profile' that maps to both?" — is plausibly out of
  scope of this problem. solution.md §Out of scope inherits from
  problem.md §Out of scope, which lists "Logout behaviour for
  providers other than Bedrock" but does *not* list "Bedrock's
  dual-credential nature". The problem statement's AC mentions only
  "the actual stored credential" (singular). So the AC, as written,
  is satisfied by the single-key alignment.
- **Backing (B):** AWS Signature Version 4 specification (requires
  both access-key-id and secret-access-key);
  `lib/tau/providers/bedrock.ex` lines 182–185.

#### Falsification attempt for claim 8

- **Strategy:** Edge-case enumeration over the Bedrock auth path.
- **Attempt:** Constructed: user runs `tau init`, selects Bedrock,
  enters value `X` when prompted for `AWS_SECRET_ACCESS_KEY`.
  Vault stores `AWS_SECRET_ACCESS_KEY=X`. User runs Tau, attempts
  inference. `Bedrock.credentials/0` checks
  `System.get_env("AWS_ACCESS_KEY_ID")` — returns `nil` (vault was
  never asked for it). Falls through to `:aws_credentials` library
  fallback. If the user has no `~/.aws/credentials` or IMDS, returns
  `nil` and authentication fails. The round-trip *for the
  acceptance criterion as written* is closed, but the *user-visible
  goal* (Bedrock works after wizard) is not.
- **Outcome:** partially falsified. The literal claim ("the actual
  stored credential is never cleared" → fixed) holds; the implicit
  goal ("Bedrock is usable after wizard") does not, because the
  wizard never collects `AWS_ACCESS_KEY_ID`.
- **Action:** Narrow the Qualifier on Claim 8 to: "round-trip is
  closed for the single credential the wizard stores; the wizard
  does not provision the full Bedrock credential set (out of scope
  per problem.md)." This does NOT trigger a solution revision because
  problem.md's §Out of scope does not require it; this is a
  follow-up worth filing as a separate problem. Flagged in
  "Outstanding doubts".

## Cross-claim consistency

Claim 3 and Claim 4 work as a pair: the new key name
(`"enabled_providers"`) only matters if the persisted shape (array of
strings) needs schema admission. Both are coherent.

Claim 5 (schema's `@known_top_level_keys` auto-updates) and Claim 8
(Bedrock round-trip) are independent; no tension.

A *latent* tension exists between Claim 1 (Catalog is the single
source of truth) and the existing `Tau.Settings.Schema.
@known_providers` literal (`schema.ex:47–54`), which is a third
provider registry. Solution §Open questions bullet 3 acknowledges this
and explicitly declares it out of scope. No internal inconsistency in
the solution, but the title "single source of truth" is therefore
*qualified*: single source of truth for the *Init↔Logout* coupling,
not for *every* provider registry in the codebase. This validator
records the narrowed reading of Claim 1.

A *new* coherence concern (separate from the above tension): the
solution does not mention `Tau.Settings.Loader.list_keys/0`
(`loader.ex:88–98`), which is a hand-maintained list of settings keys
that *concatenate* (rather than override) during cascade merge.
`enabled_providers` is an array; the schema-moduledoc (`schema.ex:
29–32`) explicitly states "every key listed here as `type: 'array'`
should appear in `Tau.Settings.Loader`'s list-merge set so cascade
semantics match". `list_keys/0` does NOT currently list
`:enabled_providers`. If a user has both `~/.tau/settings.json` (with
`enabled_providers: ["anthropic"]`) and `<cwd>/.tau/settings.json`
(with `enabled_providers: ["openai_chat"]`), the cwd layer will
*replace* (not append to) the home layer — a cascade-semantics drift
that contradicts the schema's own documented contract. This is a
mechanical follow-up: add `:enabled_providers` to
`Loader.list_keys/0`. The omission is implementation-detail oversight,
not a solution defect; flagging as Outstanding doubt 2.

## Falsification summary

| # | Claim (short) | Strategy | Outcome | Action |
|---|---|---|---|---|
| 1 | Catalog is single source of truth | dependency check + edge-case | withstood (with narrowing per X-claim §) | narrow Q to Init↔Logout coupling |
| 2 | @providers / @credential_map deleted + derived | type-level + counter-example | withstood | none |
| 3 | enabled_providers array satisfies N>1 AC | counter-example | withstood | none |
| 4 | "enabled_providers" key name correct | dependency check + counter-example | withstood | none |
| 5 | @known_top_level_keys auto-updates | type-level | withstood | none |
| 6 | Logout behaviour unchanged | counter-example over public API | withstood (with implementer note re openai/openai_chat collapse) | flag Outstanding doubt 1 |
| 7 | Satisfies OTP NN #3, #8 | type-level | withstood | none |
| 8 | Bedrock round-trip closed | edge-case enumeration | partially falsified (AC met; user-visible Bedrock auth still broken because AWS_ACCESS_KEY_ID not provisioned) | narrow Q; file follow-up |

## Revision required

No solution revision and no problem revision are triggered. The two
partial findings are:

- Claim 8's narrowed Qualifier (Bedrock dual-credential nature) lies
  *within* problem.md's §Out of scope (the problem explicitly limits
  itself to the init/logout key-name disagreement; Bedrock's full
  credential set is a separate concern). Narrowing the qualifier
  in-place is sufficient; the solution achieves the AC as written.
- Claim 1's narrowed Qualifier (Catalog is the single source for the
  *Init↔Logout* coupling, not for *all* provider registries) is
  consistent with solution.md §Open questions bullet 3, which already
  flags `@known_providers` as out of scope.

If the reader judges the Bedrock user-visible-goal gap to be
in-scope after all, the *correct* action is to amend `problem.md`
(add an Amendment log entry expanding the AC to "Bedrock auth works
end-to-end after wizard") rather than revising `solution.md`. The
solution as written is the correct response to the problem as
written. This validator recommends *not* triggering a revision unless
the user changes the AC.

- **Target file:** (none)
- **Revision kind:** (none)
- **Rationale:** All claims withstood at the AC's stated scope; the
  partial finding on Claim 8 falls inside problem.md §Out of scope.

## Outstanding doubts

1. **Catalog field design under openai_chat/openai_responses split.**
   The wizard distinguishes `:openai_chat` and `:openai_responses`
   (two separate `provider_string/1` returns), while logout collapses
   both to a single `"openai"` alias. A single `string_key` field per
   Catalog entry cannot model both. The implementer should either
   (a) give both openai entries the same `string_key` ("openai"),
   losing wizard fidelity in `"enabled_providers"`, OR (b) add a
   separate `logout_alias` field. Option (b) preserves both contracts
   and is the recommended path. Flagged for the implementer.

2. **`Tau.Settings.Loader.list_keys/0` missing
   `:enabled_providers`.** `loader.ex:88–98` is a hand-maintained
   list of array keys that *concatenate* during cascade merge. The
   schema's moduledoc explicitly requires every `type: "array"` key
   to appear in that list. The solution does not mention adding
   `:enabled_providers` to it. Without the addition, cwd-layer
   `enabled_providers` will replace (rather than extend) home-layer
   `enabled_providers`, contradicting the schema's documented
   cascade contract. This is a one-line implementer fix; flagged so
   it is not silently omitted.

3. **`Tau.Settings.Schema.@known_providers` drift.** Solution
   §Open questions bullet 3 already names this; restated here so
   the parent-level validator inherits the concern. After this PR,
   three registries describe the provider set:
   `Catalog` (atom + string_key), `@known_providers` (modules), and
   the provider source files themselves
   (`lib/tau/providers/*.ex`). Future-proofing would derive
   `@known_providers` from `Catalog` or vice versa; not required by
   this AC.

4. **Bedrock dual-credential gap.** Wizard prompts for only one of
   the two AWS credentials Bedrock auth requires. Falls inside
   problem.md §Out of scope as written. If the user-visible goal is
   "Bedrock works after wizard", this is a follow-up problem to file
   separately.
