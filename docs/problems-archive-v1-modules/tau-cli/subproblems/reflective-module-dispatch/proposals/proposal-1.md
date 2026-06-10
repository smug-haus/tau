---
template_version: 1
template_name: proposal
proposal_id: 1
parent_problem: ../problem.md
---

# Proposal 1: Delete the tail clauses — known-set closed, unknown-input error

## Approach

Remove the `Module.concat`/`String.capitalize` tail clauses from both
`resolve_provider/1` and `resolve_coding_agent/1` entirely. Replace each tail
clause with a pattern that returns `{:error, :unknown_provider, input}` /
`{:error, :unknown_coding_agent, input}`. Change the callsite(s) that receive
the resolved module to pattern-match on `{:error, reason, input}` and call
`halt(1)` with a human-readable message naming the unrecognised value. The
return type of both functions changes from `module()` to
`{:ok, module()} | {:error, :unknown_provider | :unknown_coding_agent, String.t()}`.

## Rationale

The tail clauses exist to handle a putative "open set" of custom
provider/coding-agent modules. In practice the comment at line 807–811 already
admits the clause is wrong (`"Openai" ≠ "OpenAI"`), and no production code path
benefits from it — every known provider has an explicit clause. Removing the
clause eliminates the atom leak and the silent-wrong-module defect simultaneously.
The decomplecting move is to split "input parsing" (closed-set match on a known
value) from "module derivation" (open-ended reflection), and then simply not
implement the open-ended reflection at all. The acceptance criterion's three
requirements (no atom creation from user input, clear error on unknown input,
`String.capitalize` limitation removed) are all satisfied by deletion alone.

## Sketch

```elixir
# lib/tau/cli.ex

@type resolve_error :: {:error, :unknown_provider | :unknown_coding_agent, String.t()}

# resolve_coding_agent/1 — replaces current tail clause
@doc false
def resolve_coding_agent(nil), do: {:ok, nil}
def resolve_coding_agent("claude_code"), do: {:ok, Tau.CodingAgents.ClaudeCode}
def resolve_coding_agent("claudecode"), do: {:ok, Tau.CodingAgents.ClaudeCode}
def resolve_coding_agent("replay"), do: {:ok, Tau.CodingAgents.Replay}

def resolve_coding_agent(other) when is_binary(other),
  do: {:error, :unknown_coding_agent, other}

def resolve_coding_agent(mod) when is_atom(mod), do: {:ok, mod}

# resolve_provider/1 — replaces current tail clause
defp resolve_provider(nil), do: {:ok, Tau.Provider.default()}
defp resolve_provider("anthropic"), do: {:ok, Tau.Providers.Anthropic}
# ... existing known-name clauses wrapped in {:ok, ...} ...

defp resolve_provider(other) when is_binary(other),
  do: {:error, :unknown_provider, other}

# Callsite (run_cmd/1 or wherever RuntimeOpts is built):
defp require_provider!(input) do
  case resolve_provider(input) do
    {:ok, mod} ->
      mod

    {:error, :unknown_provider, v} ->
      IO.puts(:stderr, "Unknown provider: #{inspect(v)}. Known providers: anthropic, openai, ...")
      halt(1)
  end
end
```

File changes: `lib/tau/cli.ex` only. No new modules, no new files.

## Tradeoffs

### Strengths

- Satisfies all three acceptance-criterion requirements with the minimum
  possible diff: no new abstraction, no new module, no new dependency.
- Atom leak is closed unconditionally — no path through the code can reach
  `Module.concat` from user input.
- Return type is now honest about failure; callers must handle it explicitly.
- Zero scope creep: touches only the two functions named in the problem.

### Weaknesses

- **API-breaking**: any caller that currently relies on `resolve_coding_agent/1`
  or `resolve_provider/1` returning a bare module must be updated to unwrap
  `{:ok, mod}`. This is an internal API (`@doc false` / `defp`) so scope is
  bounded, but it still requires touching every callsite.
- **Drops the open-set capability entirely**: a user who genuinely has a custom
  provider module named `Tau.Providers.MyCustom` can no longer pass
  `--provider mycustom` and have it resolved. They must add an explicit clause or
  pass the full module name through a different mechanism. This is a
  behaviour-correcting, not merely behaviour-preserving, change.
- No migration path for that use case is provided within scope; downstream
  breakage from an undocumented open-set use cannot be ruled out without a
  codebase-wide grep.

### Costs

- Callsite changes: `resolve_provider` is `defp` so all callers are local to
  `cli.ex`; estimated 1–3 callsites. `resolve_coding_agent` is `def` so callers
  may be in tests. Expected test updates: any test that passes an unknown string
  expecting a module back will need updating.
- One PR, atomic, ~30–50 lines changed.

## Dependencies

- No prerequisite changes. Self-contained.

## Confidence

Medium. The closed-set is the correct model for this function. Confidence would
be high if a codebase-wide grep confirms no caller depends on the open-set
behaviour for a string not in the known set.

## Prior art / references

- Erlang/OTP convention: atoms are finite; `String.to_existing_atom/1` (used
  elsewhere in the project, as noted in the problem's out-of-scope) is the
  sanctioned pattern for the one case where the atom already must exist.
- The `safe_to_atom/1` pattern in `Tau.CLI.Config` (out-of-scope but noted) is
  an example of the correct "only atoms that already exist" discipline.
- Elixir docs for `Module.concat/1`: "Creates a module from a list of atoms and
  binaries. Atoms are preferred over strings." — but atoms are never GC'd.
