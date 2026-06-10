---
template_version: 1
template_name: proposal
proposal_id: 3
parent_problem: ../problem.md
---

# Proposal 3: Fix `List.first` by correcting the prompt to single-select; fix Bedrock key in `Init`

## Approach

Reinterpret the `List.first` call not as a bug-to-be-removed but as a
design constraint to be made explicit: change the provider-selection
prompt from multi-select (plural language, comma-separated input) to
single-select (unambiguous single choice), so `List.first` is no longer
truncating — it is taking the sole element of a length-1 list. Separately,
fix the Bedrock `env` value in `Init.@providers` from `"AWS_ACCESS_KEY_ID"`
to `"AWS_SECRET_ACCESS_KEY"` to match `Logout.@credential_map`. This
approach preserves the existing settings schema (`"provider"` as a string),
keeps both `@providers` and `@credential_map` as independent module
attributes, and avoids any schema change. Credential collection still
runs for all configured providers; only the "active provider" concept is
narrowed to one.

## Rationale

The acceptance criterion has two parts: (a) settings reflect all N
selections, and (b) init and logout agree on the Bedrock credential key.
This proposal satisfies (b) unconditionally. For (a), it satisfies it by
redefining the prompt semantics: the settings schema's `"provider"` key is
a string (single value); if the schema does not support a list, then
prompting for multiple selections and then silently discarding them is
the actual bug — the fix is to align the prompt with what the schema can
store, rather than to change the schema. The credential collection step
(which already iterates all selected providers) is preserved or adapted so
users can still configure credentials for providers other than the primary,
but only one provider is written to `"provider"`. This is a
behaviour-preserving refactor with respect to the settings schema and the
logout command.

## Sketch

### 1. Fix Bedrock credential key in `Init.@providers`

```elixir
# lib/tau/cli/init.ex — same one-line fix as other proposals
@providers [
  %{key: :anthropic,         label: "Anthropic",          env: "ANTHROPIC_API_KEY"},
  %{key: :openai_chat,       label: "OpenAI Chat",         env: "OPENAI_API_KEY"},
  %{key: :openai_responses,  label: "OpenAI Responses",    env: "OPENAI_API_KEY"},
  %{key: :gemini,            label: "Gemini",              env: "GEMINI_API_KEY"},
  %{key: :bedrock,           label: "Bedrock",             env: "AWS_SECRET_ACCESS_KEY"}  # FIXED
]
```

### 2. Rewrite `provider_selection/1` as single-select

```elixir
# lib/tau/cli/init.ex — replace provider_selection/1

defp provider_selection(io) do
  io.puts("")
  io.puts("[1/5] Which provider do you want to use?")

  @providers
  |> Enum.with_index(1)
  |> Enum.each(fn {p, i} ->
    io.puts("  [#{i}] #{p.label} (env: #{p.env})")
  end)

  raw = prompt(io, "index (default: 1): ")

  case parse_single_provider_index(raw) do
    nil -> List.first(@providers).key
    key -> key
  end
end

defp parse_single_provider_index(""), do: nil
defp parse_single_provider_index(nil), do: nil

defp parse_single_provider_index(str) do
  str = String.trim(str)
  case Integer.parse(str) do
    {n, ""} when n >= 1 and n <= length(@providers) ->
      Enum.at(@providers, n - 1).key
    _ ->
      nil
  end
end
```

`provider_selection/1` now returns a single atom rather than a list.

### 3. Adapt callers

`drive_flow/1` and `handle_credentials/3` receive a single atom, not a
list. Minimal change:

```elixir
# drive_flow — provider is now an atom, not a list
provider = provider_selection(io)            # atom
creds_summary = handle_credentials(io, [provider], non_interactive?)

new_settings =
  base_settings
  |> Map.put("permissions", merge_permissions(base_settings, perms_mode))
  |> Map.put("provider", provider_string(provider))  # no List.first needed
```

### 4. Credential collection: optionally extend to multi-provider credential setup

To allow credential collection for providers other than the primary (e.g.
for fallback chains), an optional second step can ask "Configure credentials
for additional providers? (y/N)" and, if yes, present the same credential
prompts for additional providers without writing them to `"provider"`. This
is additive and does not change the `"provider"` key in settings. This
sub-step is optional within this proposal.

### File moves

```
(mod)  lib/tau/cli/init.ex  — @providers bedrock fix; provider_selection rewrite
(none) lib/tau/commands/builtin/logout.ex  — unchanged
(none) lib/tau/settings/schema.ex         — unchanged
```

## Tradeoffs

### Strengths

- No schema change required; fully backwards-compatible settings files.
- Simplest callsite: `provider_string(provider)` — no `List.first`, no
  list comprehension, no possible truncation.
- Does not require a new module or any new abstraction.
- Logout is completely untouched (only the Bedrock key fix in Init is
  needed).
- The root cause of the `List.first` surprise — a multi-select UI feeding
  a single-value schema field — is eliminated rather than papered over.

### Weaknesses

- Does NOT satisfy "settings reflect all N selections" if the user genuinely
  wants multiple provider strings persisted. This proposal reframes the
  problem: the AC's "all N selections" becomes N=1 by fixing the UX contract.
  If the product intent is truly multi-provider persistence, this proposal
  is wrong; it redefines the acceptance criterion rather than meeting it.
- Credential duplication between `Init.@providers` and
  `Logout.@credential_map` remains; they can still drift in the future.
- Reduces wizard functionality: users cannot select multiple providers in
  a single `tau init` run (they must re-run for each).
- `parse_provider_indices` (the multi-index parser) is no longer used and
  can be deleted, but its deletion is a small dead-code cleanup cost.

### Costs

- 1 file changed (`init.ex`), ~30 lines.
- Test updates: `test/tau/cli/init_test.exs` — multi-provider selection
  tests must change to reflect single-select semantics; tests that assert
  multi-provider persistence will fail and must be removed or rewritten.
  This is potentially a significant test-surface impact if the test suite
  has comprehensive multi-select coverage.
- No schema migration needed.

## Dependencies

- None. This proposal is self-contained in `init.ex`.

## Confidence

medium — the fix is technically straightforward, but whether the product
intent supports reducing multi-select to single-select is a product
question, not an engineering one. Confidence in the implementation is high;
confidence that this satisfies the product acceptance criterion depends on
that judgement.

## Prior art / references

- `lib/tau/settings/schema.ex:69` — `"provider" => %{"type" => "string"}`:
  the schema constraint that motivates treating single-select as the
  semantically correct behaviour.
- Conventional CLI wizards (e.g. `mix phx.new`) prompt for one primary
  adapter and optionally extend; multi-select-that-silently-truncates is
  an anti-pattern.
- `lib/tau/cli/init.ex:136–139` — `provider_selection/1` return value
  already handles the empty-selection fallback to `[List.first(@providers).key]`,
  showing the single-provider fallback was always the intended default.
