---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Unify credential map in `Init` and fix `List.first` — inlined correction

## Approach

Correct both defects entirely within `lib/tau/cli/init.ex` and
`lib/tau/commands/builtin/logout.ex`, touching no other module. Change
`@providers` in `Init` so `:bedrock` maps to `"AWS_SECRET_ACCESS_KEY"`
(matching `Logout.@credential_map`). Change `new_settings` construction
at line 153 to persist a list of provider strings rather than a single
string (requires the settings schema to accept either `"provider"` as a
string for single-provider backwards-compat, or a new `"providers"` array
key — see Sketch). No new module is introduced; the two files become
independently correct and their credential maps happen to agree.

## Rationale

The complecting hypothesis names two separate modules holding divergent
knowledge about the same fact (which vault key names Bedrock's credential).
The minimal decomplect is to correct the wrong one: `Init` stores
`AWS_ACCESS_KEY_ID` but `Logout` deletes `AWS_SECRET_ACCESS_KEY`; the
Bedrock provider's env var for authentication is `AWS_SECRET_ACCESS_KEY`,
so `Init` is the incorrect one. This proposal corrects `Init` and also
fixes the `List.first` truncation in the same atomic change. No structural
refactor is required — the duplication remains, but the two copies agree.
The tradeoff is that they can drift again in the future, but the immediate
defects are resolved without touching the settings schema or introducing a
new abstraction.

## Sketch

### 1. Fix credential key in `Init.@providers`

```elixir
# lib/tau/cli/init.ex — before
@providers [
  %{key: :anthropic, label: "Anthropic",           env: "ANTHROPIC_API_KEY"},
  %{key: :openai_chat, label: "OpenAI Chat",        env: "OPENAI_API_KEY"},
  %{key: :openai_responses, label: "OpenAI Responses", env: "OPENAI_API_KEY"},
  %{key: :gemini, label: "Gemini",                  env: "GEMINI_API_KEY"},
  %{key: :bedrock, label: "Bedrock",                env: "AWS_ACCESS_KEY_ID"}  # WRONG
]

# After
@providers [
  %{key: :anthropic, label: "Anthropic",           env: "ANTHROPIC_API_KEY"},
  %{key: :openai_chat, label: "OpenAI Chat",        env: "OPENAI_API_KEY"},
  %{key: :openai_responses, label: "OpenAI Responses", env: "OPENAI_API_KEY"},
  %{key: :gemini, label: "Gemini",                  env: "GEMINI_API_KEY"},
  %{key: :bedrock, label: "Bedrock",                env: "AWS_SECRET_ACCESS_KEY"}  # FIXED
]
```

### 2. Fix `List.first` truncation

The settings schema's `"provider"` key is `"type" => "string"`, which
cannot hold a list. Two options exist at this sub-step:

**Option A** — persist only the first provider in `"provider"` (schema
stays unchanged), but correct the prompt text to say "primary provider"
rather than implying multi-select:

```elixir
# lib/tau/cli/init.ex line ~153
|> Map.put("provider", providers |> List.first() |> provider_string())
```

This keeps `List.first` but changes the prompt from "[1/5] Which providers
do you want to enable?" to "[1/5] Which providers do you want to configure
credentials for? (first selection becomes active provider)".

**Option B** — persist the full list under a new `"providers"` key (schema
must be extended to allow `"providers": ["string"]`), keeping `"provider"`
as the primary active provider for backwards-compat:

```elixir
# lib/tau/cli/init.ex line ~150-154
|> Map.put("provider", providers |> List.first() |> provider_string())
|> Map.put("providers", Enum.map(providers, &provider_string/1))
```

The acceptance criterion says "the written `settings.local.json` reflects
all N selections", which Option B satisfies; Option A only satisfies it if
the problem's intent is that credentials are stored for all N, even if only
one is the active provider. Given the credential-handling step already
iterates all `providers`, Option B is recommended within this proposal.

### Schema amendment (Option B)

```elixir
# lib/tau/settings/schema.ex — add to "properties"
"providers" => %{
  "type" => "array",
  "items" => %{"type" => "string"}
}
```

## Tradeoffs

### Strengths

- Smallest diff: two files changed (three counting the schema amendment),
  no new modules.
- No API surface change for callers of `Init.run/2`.
- Credential key fix is obviously correct and verifiable by inspection.
- No new abstractions to test; existing unit tests for `run/2` and
  `Logout.run/2` can be updated directly.

### Weaknesses

- The duplication between `Init.@providers` and `Logout.@credential_map`
  persists; they remain free to drift again in the future.
- Option A does not fully satisfy the acceptance criterion (all N
  selections persisted); it only satisfies credential storage for all N.
- Schema amendment (Option B) is a dependency that must land atomically
  with the wizard fix or `validate/1` will reject the new key.
- No structural enforcement: a future contributor editing either file
  independently will not be warned about the coupling.

### Costs

- 2–3 files changed.
- Test updates: `test/tau/cli/init_test.exs` (multi-provider selection
  assertions), `test/tau/commands/builtin/logout_test.exs` (credential key
  assertion). Likely < 20 lines of test change.
- Schema change is additive (no existing JSON breaks); existing
  `settings.local.json` files without the `"providers"` key remain valid.

## Dependencies

- If Option B: the `"providers"` schema key must be added to
  `Tau.Settings.Schema` in the same PR so `validate/1` accepts it.
- No other external dependencies.

## Confidence

medium — the fix logic is straightforward and the code paths are short.
Confidence would rise to high after a `mix test` run confirming no
schema-validation regressions and a manual trace of the Bedrock credential
round-trip (init → vault → logout).

## Prior art / references

- `lib/tau/settings/schema.ex:69` — current `"provider"` key definition
  (string only).
- `lib/tau/cli/init.ex:245–253` — `handle_credentials/3` already maps over
  all selected providers; the fix at line 153 mirrors that iteration pattern.
- `lib/tau/commands/builtin/logout.ex:38–43` — the authoritative credential
  key names (treated as correct in this proposal).
