---
template_version: 1
template_name: proposal
proposal_id: 2
parent_problem: ../problem.md
---

# Proposal 2: Static registry map — data-driven closed set, `String.to_existing_atom` validation

## Approach

Replace the function-clause dispatch in both `resolve_provider/1` and
`resolve_coding_agent/1` with module attributes that define the complete
allowed-string-to-module mapping as a `%{String.t() => module()}` map. The
tail clause is replaced by a map lookup that returns `{:error, :unknown}` on
miss. No `Module.concat`, no atom creation from user input. The maps become
the single source of truth for the project's known short names; the
`String.capitalize` code path is removed entirely.

## Rationale

The current implementation conflates two distinct responsibilities inside function
clauses: (1) a lookup table of string → module, and (2) a reflective
fallback. Separating these by making the lookup table explicit as a module
attribute turns the "closed set" into a data structure that is
introspectable (for documentation, `--help` output, error messages that list
valid values). The reflective fallback is simply not added. The atom-leak
concern disappears because map keys are compile-time string literals and map
lookups produce existing atoms (the module literals) or `nil`.

## Sketch

```elixir
# lib/tau/cli.ex  (module attribute section)

@provider_registry %{
  "anthropic"   => Tau.Providers.Anthropic,
  "openai"      => Tau.Providers.OpenAI.Chat,
  "ollama"      => Tau.Providers.OpenAI.Chat,
  "local"       => Tau.Providers.OpenAI.Chat,
  "bedrock"     => Tau.Providers.Bedrock,
  "gemini"      => Tau.Providers.Gemini,
  "deepseek"    => Tau.Providers.DeepSeek,
  "groq"        => Tau.Providers.Groq,
  "mistral"     => Tau.Providers.Mistral,
  "azure"       => Tau.Providers.AzureOpenAI,
  "azure-openai"=> Tau.Providers.AzureOpenAI,
  "custom"      => Tau.Providers.Custom,
  "replay"      => Tau.Providers.Replay
}

@coding_agent_registry %{
  "claude_code" => Tau.CodingAgents.ClaudeCode,
  "claudecode"  => Tau.CodingAgents.ClaudeCode,
  "replay"      => Tau.CodingAgents.Replay
}

# resolve_provider/1 — replaces all current clauses
defp resolve_provider(nil), do: {:ok, Tau.Provider.default()}

defp resolve_provider(name) when is_binary(name) do
  case Map.fetch(@provider_registry, name) do
    {:ok, mod} -> {:ok, mod}
    :error     -> {:error, :unknown_provider, name, Map.keys(@provider_registry)}
  end
end

# resolve_coding_agent/1 — replaces all current clauses
def resolve_coding_agent(nil), do: {:ok, nil}

def resolve_coding_agent(mod) when is_atom(mod), do: {:ok, mod}

def resolve_coding_agent(name) when is_binary(name) do
  case Map.fetch(@coding_agent_registry, name) do
    {:ok, mod} -> {:ok, mod}
    :error     -> {:error, :unknown_coding_agent, name, Map.keys(@coding_agent_registry)}
  end
end

# Error tuple carries the known-values list so callers can print:
# "Unknown provider 'foo'. Known providers: anthropic, bedrock, ..."
```

The error tuple is `{:error, :unknown_provider | :unknown_coding_agent, String.t(), [String.t()]}` —
the fourth element is the list of valid keys, enabling rich error messages
without hard-coding the list a second time in the error handler.

File changes: `lib/tau/cli.ex` only.

## Tradeoffs

### Strengths

- No `Module.concat`, no `String.capitalize`, no atom leak — acceptance
  criterion fully satisfied.
- The registry map is the single source of truth for valid short names; the
  `--help` / error message can enumerate it without duplication.
- Error messages can include "did you mean one of: ..." without a separate
  constant, reducing the chance of documentation drift.
- Behaviour-preserving for the closed known-set: all currently-working inputs
  continue to resolve to the same module.
- Easy to extend: adding a new provider is one map entry, not a new function
  clause.

### Weaknesses

- **API-breaking** in the same way as Proposal 1: return type changes from
  `module()` to tagged tuple; all callsites must be updated.
- **More surface area than Proposal 1**: the map attribute is a new concept
  in a file that currently uses function-clause dispatch everywhere else; it
  departs from the local idiom.
- **Still drops open-set capability**: same tradeoff as Proposal 1 — custom
  module strings that are not in the map will error.
- Pattern-match on function clauses is compiled to a jump table by the BEAM;
  map lookup is a hash lookup. Both are O(1) for the sizes involved, but the
  perf characteristic is different. Not a practical concern at CLI startup.

### Costs

- Callsite changes: same as Proposal 1. Estimated 1–3 for `resolve_provider`,
  somewhat more for `resolve_coding_agent` since it is public.
- The four-tuple error type is slightly more complex to handle than a
  two-tuple; callers must destructure or ignore the hints list.
- Test updates: tests for known strings need no change; tests passing unknown
  strings expecting a module back will fail and need updating.

## Dependencies

- No prerequisite changes. Self-contained within `lib/tau/cli.ex`.

## Confidence

Medium-high. The map-registry pattern is used widely in Elixir CLI tools
for `--option value` validation (e.g. `OptionParser` atom coercion, `ExDoc`
formatter registry). Confidence would be high after verifying all callsites
in tests.

## Prior art / references

- Elixir standard library `OptionParser` — uses atom keys in a keyword list
  (effectively a static registry) for `--switches` type coercion.
- Phoenix `plug_router` approach: route → handler is a compile-time map;
  the pattern is ubiquitous in the BEAM ecosystem.
- `Tau.CLI.Config.safe_to_atom/1` (project-internal, noted in problem
  out-of-scope) demonstrates the project's existing preference for
  existing-atom-only patterns.
