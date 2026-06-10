---
template_version: 1
template_name: solution
parent_problem: ../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md]
selection_method: single
revision: 1
---

# Solution: Extract `Tau.Providers.Catalog` as single source of truth

## Recommendation

Introduce `lib/tau/providers/catalog.ex` — a pure compile-time data module — as
the single authoritative registry mapping each provider atom to its label,
vault credential name, and settings string key. Delete `Init.@providers` and
`Logout.@credential_map`; both modules derive their provider knowledge from
`Catalog` at compile time. Fix the `List.first` truncation by persisting all
selected provider strings under a **new `"enabled_providers"` array key** in
`settings.local.json` (with `"provider"` retaining the first selection for
backwards compatibility), and add the corresponding array schema entry to
`Tau.Settings.Schema`. The key name is deliberately `"enabled_providers"`,
not `"providers"`: the latter is already defined at
`lib/tau/settings/schema.ex:121` as an OBJECT for ADR-0012 per-provider
fallback chains, and the schema enforces `additionalProperties: false` at the
top level, so reusing `"providers"` would be both a type-shape collision (array
vs object) and a semantic collision (enablement set vs fallback-chain config).
This is the only proposal that structurally prevents future credential-key
drift while fully satisfying both halves of the acceptance criterion without
breaking any existing top-level key.

## Selected from

- **Chosen:** `proposals/proposal-2.md` — Extract `Tau.Providers.Catalog`

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|---|---|---|---|---|
| 1 | Partially | Surface | Low | Low | Easy |
| 2 | Yes | Deep | Medium | Low | Easy |
| 3 | Partially | Surface | Low | Low | Easy |
| 4 | Yes | Surface | Low | Low | Easy |

**Why chosen:** Proposal 2 is the only one that scores Yes on fit AND Deep on
decomplecting depth. Proposal 1 scores Partially because it leaves the
duplication in place with no enforcement — drift recurs as soon as either file
is edited independently. Proposal 3 scores Partially because it satisfies the
acceptance criterion only by redefining it (single-select reframes "all N
selections" to N=1), which is a product-level change the problem statement does
not permit; the AC is explicit that N > 1 providers must be reflected. Proposal
4 scores Yes on fit but Surface on decomplecting depth: the parity test reduces
drift risk but does not remove the duplicated fact — two copies still exist,
the test covers only their intersection, and new providers added asymmetrically
remain invisible. Proposal 2 removes the duplicated fact entirely. The new
module is pure data (no GenServer, no ETS, no runtime state), consistent with
OTP non-negotiables #3 and #8. Migration cost is Medium rather than Low only
because a new file is introduced and two call sites are refactored; the
compile-time derivation pattern is idiomatic Elixir and carries no runtime
cost. Reversibility is Easy: the module can be deleted and the original
`@providers` / `@credential_map` literals restored atomically. The proposal's
own sketch suggested writing the enablement list to a `"providers"` array key;
revision 1 of this solution corrects that to `"enabled_providers"` (see
`Schema collision discovery` below) — the substance of the chosen approach is
unchanged.

## What changes

- **New:** `lib/tau/providers/catalog.ex` — defines `@entries` with `key`,
  `label`, `env_var`, `string_key` per provider; exposes `all/0`, `by_key/1`,
  `by_string_key/1`, `credential_map/0`.
- **New:** `test/tau/providers/catalog_test.exs` — property tests asserting
  every entry has non-nil `env_var`, all `:key` atoms are unique, all
  `:string_key` strings are unique.
- **Modify:** `lib/tau/cli/init.ex`
  - Delete `@providers` module attribute.
  - `alias Tau.Providers.Catalog`; replace all `@providers` references with
    `Catalog.all()`.
  - Fix `drive_flow/1`: replace `Map.put("provider", providers |> List.first() |> provider_string())` with both `Map.put("provider", ...)` (first selection, unchanged for backwards compatibility) and `Map.put("enabled_providers", Enum.map(providers, &Catalog.by_key(&1).string_key))` (new array key carrying all N selections).
- **Modify:** `lib/tau/commands/builtin/logout.ex`
  - Delete `@credential_map` literal.
  - `alias Tau.Providers.Catalog`; add `@credential_map Catalog.credential_map()` (compile-time derivation — no runtime cost, no behaviour change).
- **Modify:** `lib/tau/settings/schema.ex`
  - Add `"enabled_providers" => %{"type" => "array", "items" => %{"type" => "string"}}` to the top-level `"properties"` map. MUST NOT reuse the existing `"providers"` key (line 121), which is an object reserved for ADR-0012 fallback chains. `@known_top_level_keys` is derived from `Map.keys(properties)` at compile time, so the new entry is picked up automatically.
- **Modify:** `test/tau/cli/init_test.exs` — add assertions that written
  settings include `"enabled_providers"` list reflecting all selected
  providers, and that `"provider"` (singular) is the first selection.

## What does not change

- `Tau.Settings.Vault.put/2` and `Tau.Settings.Vault.delete/1` — operate on
  vault key names directly; no change needed.
- `Logout.run/2` body logic — `@credential_map` is now compile-time derived
  from `Catalog`; the map value and all pattern matches are identical.
- The `"provider"` (singular) key in `settings.local.json` — retained for
  backwards compatibility with any code reading the active provider.
- The existing `"providers"` (plural) key at `schema.ex:121` — remains an
  object holding the ADR-0012 fallback-chain block
  (`%{"fallback_chains" => %{...}}`). No shape change, no semantic change.
- `Tau.Settings.Schema.resolve_fallback_chains/1` — still consumes
  `settings["providers"]`; the new `"enabled_providers"` key is consumed by
  wizard / read-back code only.
- `provider_string/1` helper in `Init` — still used for the `"provider"`
  singular key; may be replaced by `Catalog.by_key/1` lookup but is not
  required to be.
- All other `Init` wizard steps (permissions, non-interactive mode, credential
  prompts).
- `Tau.Commands.Builtin.Logout` credential removal logic — unchanged.

## Migration sketch

1. Land `lib/tau/providers/catalog.ex` and `test/tau/providers/catalog_test.exs`
   first; the new module has no callers yet so it cannot break anything.
2. Add the `"enabled_providers"` array key to `Tau.Settings.Schema` in the same
   commit (additive top-level key; the existing `"providers"` object is
   untouched, and `additionalProperties: false` at the top level admits the new
   key because it is explicitly listed). Existing `settings.local.json` files
   without the key remain valid.
3. Refactor `Init`: delete `@providers`, alias `Catalog`, fix `drive_flow/1` to
   write both `"provider"` and `"enabled_providers"`. Update
   `test/tau/cli/init_test.exs` to assert the new key.
4. Refactor `Logout`: delete `@credential_map` literal, derive from
   `Catalog.credential_map()` at compile time. No test changes expected (the
   map values are identical; existing tests pass).
5. Run `mix compile --warnings-as-errors && mix test`. The Bedrock credential
   round-trip (init → vault → logout) is verifiable by tracing
   `Catalog.by_key(:bedrock).env_var` → `"AWS_SECRET_ACCESS_KEY"` →
   `Logout.@credential_map["bedrock"]`. Schema acceptance is verifiable by
   `Tau.Settings.Schema.json_schema/0 |> Map.fetch!("properties") |> Map.keys()`
   including both `"providers"` (existing object) and `"enabled_providers"`
   (new array) without collision.

## Schema collision discovery (revision 1)

Revision 0 of this solution proposed writing the enablement list to a new
top-level `"providers"` key as an array. Inspection of
`lib/tau/settings/schema.ex` at the line cited in the revision instruction
falsified that choice:

- `schema.ex:121` already declares `"providers"` as
  `%{"type" => "object", "additionalProperties" => true, "properties" => %{"fallback_chains" => ...}}`
  — an object reserved by ADR-0012 for per-provider fallback chains.
- `schema.ex:66` sets `"additionalProperties" => false` at the top level, and
  `@known_top_level_keys` (line 216) is derived from
  `Map.keys(@schema["properties"])` at compile time. Adding a second
  `"properties"` entry under the same key is a literal map-key collision
  (Elixir map-literal duplicate-key warning) and would either silently
  overwrite the ADR-0012 entry or fail to compile under
  `--warnings-as-errors`.
- Even if the literal collision were avoided by an in-place mutation, the
  JSON-Schema validator would reject every existing valid
  `settings.local.json` whose `"providers"` is an object (the canonical
  ADR-0012 shape) against a redefined `"type": "array"`.

`"enabled_providers"` was chosen as the replacement key name because it (a)
does not appear in the current top-level key set —
`model, provider, data_dir, theme, permissions, mcp, hooks, extensions,
allow, deny, ask, providers, rate_limits, vault, coding_agent, otel` — (b)
reads as semantically distinct from `"providers"` (enablement set vs
fallback-chain configuration), and (c) is consistent with the schema's
existing snake_case convention (`data_dir`, `rate_limits`, `coding_agent`).
No other top-level key collisions were found.

## Open questions

- `Catalog.by_key/1` returns `nil` for an unknown atom. `drive_flow/1` must
  guard this path (e.g. filter out `nil` entries or raise at init time). The
  proposal sketches the nil path but does not specify the error handling
  strategy; the implementer should apply a `Enum.reject(&is_nil/1)` or a
  pattern-match guard consistent with OTP non-negotiable #7 (let it crash on
  programmer error, not user input).
- Whether `provider_string/1` in `Init` should be deleted in favour of
  `Catalog.by_key(k).string_key` is a readability question. Both work; the
  implementer may decide.
- `Tau.Settings.Schema.@known_providers` (line 47–54) is a separate registry
  that lists provider modules (full `Tau.Providers.*` names) for ADR-0012
  fallback-chain resolution. After this change, `Catalog` (wizard-side,
  string keys like `"anthropic"`) and `@known_providers` (chain-side, module
  references) are two compile-time lists describing overlapping provider
  sets. They do NOT collide on key namespace (the wizard's `string_key` is
  the short alias; `@known_providers` holds fully-qualified module names),
  but they can drift on coverage (e.g. add a provider to `@known_providers`
  but not to `Catalog`). This proposal does not address that drift (out of
  scope per problem.md), but the implementer should note it and optionally
  derive `@known_providers` from `Catalog` (or vice versa) in a follow-up if
  the mapping is trivially safe.
- Whether a future PR should rename the singular `"provider"` key to
  `"default_provider"` and treat `"enabled_providers"` as the sole list of
  record. Currently both are retained for backwards compatibility; a future
  schema-cleanup PR could deprecate the singular form.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Inlined correction; fixes both bugs in place
  without a new module. Selected against: leaves duplication intact; scored
  Partially on fit (no structural enforcement of future agreement).
- `proposals/proposal-2.md` — Extract `Tau.Providers.Catalog`; single source
  of truth at compile time. **Selected.**
- `proposals/proposal-3.md` — Single-select reframe; changes the UX contract
  to match the existing schema rather than extending the schema. Selected
  against: redefines the acceptance criterion rather than satisfying it.
- `proposals/proposal-4.md` — Inline fix plus parity test. Selected against:
  decomplects at test layer only; the duplicated fact and its drift risk
  remain in production code.

## Revision history

- (revision 0 — initial selection of proposal-2)
- (revision 1 — schema-key collision fix: changed the new array key from
  `"providers"` to `"enabled_providers"` after inspection of
  `lib/tau/settings/schema.ex:121` confirmed `"providers"` is already
  defined as an ADR-0012 fallback-chain object and the top level uses
  `additionalProperties: false`. Verified no other top-level key
  collisions: the chosen name is absent from `@known_top_level_keys`. The
  underlying selection of proposal-2 is unchanged; only the persisted-key
  identifier and the schema entry differ.)
