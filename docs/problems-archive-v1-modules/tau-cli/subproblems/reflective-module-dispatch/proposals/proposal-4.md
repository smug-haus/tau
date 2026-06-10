---
template_version: 1
template_name: proposal
proposal_id: 4
parent_problem: ../problem.md
---

# Proposal 4: Input-validation façade at the CLI boundary — reject before resolution

## Approach

Do not change the internals of `resolve_provider/1` or `resolve_coding_agent/1`
at all. Instead, insert an explicit validation step at the Optimus argument
parsing boundary — before either function is called — that checks the
`--provider` and `--coding-agent` flag values against an allowlist of known
short-name strings. Unknown values are rejected at the CLI boundary with a
usage-style error message and `halt(1)`, so the `Module.concat` tail clauses are
never reached in practice. In a separate, follow-on change (not this PR), the
tail clauses are removed because they are now dead code. The `String.capitalize`
limitation is also documented as a `@deprecated` or removed comment warning
since the open-set path becomes inaccessible.

## Rationale

The atom-leak is a runtime hazard only if user input reaches `Module.concat`.
If it never reaches that call, the hazard is closed. Inserting the guard at the
CLI boundary is the "parse, don't validate" principle applied inward: by the
time `run_cmd/1` calls `resolve_provider`, the string has already been validated
to be a known member. This decomplects the CLI boundary concern (valid user
input) from the resolution concern (string → module). It is also the most
incremental path: the resolution functions are left structurally intact in this
PR, and the tail-clause deletion is a trivial follow-on.

## Sketch

```elixir
# lib/tau/cli.ex — add before run_cmd/1 or in the Optimus post-parse step

@known_provider_strings ~w[
  anthropic openai ollama local bedrock gemini deepseek groq
  mistral azure azure-openai custom replay
]

@known_coding_agent_strings ~w[claude_code claudecode replay]

# Validation function — called immediately after Optimus.parse! returns
defp validate_cli_args!(parsed_args) do
  with :ok <- validate_provider(parsed_args),
       :ok <- validate_coding_agent(parsed_args) do
    :ok
  else
    {:error, :unknown_provider, v} ->
      IO.puts(:stderr,
        "Unknown --provider value: #{inspect(v)}.\n" <>
        "Known values: #{Enum.join(@known_provider_strings, ", ")}"
      )
      halt(1)

    {:error, :unknown_coding_agent, v} ->
      IO.puts(:stderr,
        "Unknown --coding-agent value: #{inspect(v)}.\n" <>
        "Known values: #{Enum.join(@known_coding_agent_strings, ", ")}"
      )
      halt(1)
  end
end

defp validate_provider(args) do
  case args[:provider] do
    nil -> :ok
    v when v in @known_provider_strings -> :ok
    v -> {:error, :unknown_provider, v}
  end
end

defp validate_coding_agent(args) do
  case args[:coding_agent] do
    nil -> :ok
    v when v in @known_coding_agent_strings -> :ok
    v -> {:error, :unknown_coding_agent, v}
  end
end

# resolve_provider/1 and resolve_coding_agent/1 are UNCHANGED in this PR.
# The tail clauses become dead code; removal is a separate PR.
```

`validate_cli_args!` is called once per command dispatch, after Optimus parsing
and before `run_cmd/1`. This adds a single guard layer without restructuring
the resolution logic.

File changes: `lib/tau/cli.ex` only (add ~30 lines; no existing code deleted in
this PR).

## Tradeoffs

### Strengths

- **Behaviour-preserving and non-breaking**: `resolve_provider/1` and
  `resolve_coding_agent/1` signatures are unchanged; no callsite updates
  required; no test changes to existing tests.
- **Minimal diff in this PR**: ~30 lines added; no deletions. Easiest to
  review and least likely to introduce a regression.
- **Incremental**: the tail-clause deletion is a trivial follow-on PR that
  removes dead code. The two PRs together complete the fix; neither is risky
  alone.
- **Atom leak is closed immediately**: the guard fires before `Module.concat`
  is reached, satisfying the acceptance criterion.
- Clear error messages enumerate the known values using the `@known_*_strings`
  attributes, which are the single source of truth for the validation step.

### Weaknesses

- **Duplicates the known-names list**: `@known_provider_strings` and the
  existing function clauses in `resolve_provider/1` are now two representations
  of the same closed set. If a new provider is added, both must be updated —
  the exact coupling problem Proposal 2 and 3 solve. This is the central
  weakness.
- **Does not remove `String.capitalize` in this PR**: the comment at line
  807–811 ("wrong for compound names") remains until the follow-on PR. The
  acceptance criterion includes "documented limitation is removed", which
  technically requires the follow-on.
- **Tail clauses remain as dead code** until the follow-on PR: a future reader
  who does not know the guard exists may re-enable or rely on the tail clause.
- **Open-set capability is removed silently** at the boundary without a clear
  migration path: a user with `--provider mycustom` gets "unknown provider"
  where before they got (wrongly-cased) module resolution.

### Costs

- This PR: ~30 lines added to `lib/tau/cli.ex`. No signature changes, no
  other file changes, no test changes.
- Follow-on PR (tail-clause deletion): ~15 lines deleted.
- Total cost across both PRs is comparable to Proposal 1, but requires two
  PRs rather than one.

## Dependencies

- No prerequisite changes.
- The follow-on deletion PR depends on this PR merging first (the tail clauses
  are only safe to delete after the guard is in place).

## Confidence

High. The pattern is trivially correct: a guard that rejects non-members of a
compile-time set cannot leak atoms because it calls `halt(1)` before any atom
creation. No new abstraction, no behaviour change for valid inputs.

## Prior art / references

- "Parse, don't validate" (Alexis King, 2019): parse user input into a known
  type at the boundary; do not pass unvalidated strings inward.
- Elixir's own `OptionParser` `:switches` option — validates that flag values
  belong to the declared type at parse time, before the application sees them.
- Standard CLI idiom: `argparse` (Python), `clap` (Rust), and `optparse` (Ruby)
  all validate enum-constrained flag values at the boundary, before dispatch.
