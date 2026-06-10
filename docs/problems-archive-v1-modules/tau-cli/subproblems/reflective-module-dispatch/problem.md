---
template_version: 1
template_name: problem
node_kind: leaf
depth: 1
parent: ../../problem.md
status: draft
---

# Problem: resolve_provider and resolve_coding_agent build modules from arbitrary user strings

## Statement

The tail clauses of `Tau.CLI.resolve_provider/1` and
`Tau.CLI.resolve_coding_agent/1` call `Module.concat(["Tau", "Providers",
String.capitalize(other)])` and `Module.concat(["Tau", "CodingAgents",
String.capitalize(other)])` on any string that does not match a known short
name. `String.capitalize/1` applies only to the first byte, so compound names
like `"openai"` produce `Tau.Providers.Openai` rather than
`Tau.Providers.OpenAI`; the code even acknowledges this in a comment but ships
the defect anyway. More broadly, `Module.concat/1` with an atom-producing path
derived from user input unconditionally occupies an atom-table slot per unique
CLI invocation, which is an atom-leak from a bounded resource.

## Context

- `lib/tau/cli.ex:782–788` — `resolve_coding_agent/1` tail clause:
  `Module.concat(["Tau", "CodingAgents", String.capitalize(other)])`.
- `lib/tau/cli.ex:812–814` — `resolve_provider/1` tail clause:
  `Module.concat(["Tau", "Providers", String.capitalize(other)])`. Comment
  at line 807–811 explains the `String.capitalize/1` limitation but accepts it.
- `String.capitalize/1` uppercases only the first codepoint; "openai" → "Openai",
  not "OpenAI". The known short names above handle all production providers; this
  tail clause is only reachable with genuinely custom provider modules.
- Elixir atoms are never garbage collected; `Module.concat/1` interns a new atom
  for every distinct user-supplied string that reaches the tail clause.
- The Optimus CLI surface provides no input validation before these functions
  are called, so any string from `--provider` / `--coding-agent` can reach the
  tail clause.

## Complecting hypothesis

- Known-name resolution is complected with open-ended module derivation in the
  same function: the early clauses handle the closed set of registered providers
  while the tail clause attempts to handle an open set via reflection, coupling
  "parse a known flag value" to "create arbitrary atoms from user input".

## Decomposition strategy

(leaf — no further decomposition; proceed to proposals)

## Acceptance criterion

`resolve_provider/1` and `resolve_coding_agent/1` do not create atoms from
arbitrary user-supplied strings; unknown provider/coding-agent strings are
rejected with a clear error message before any atom is created; the documented
`String.capitalize/1` limitation is removed.

## Out of scope

- `Tau.CLI.MCP.transport_for/1` string-vs-atom key probing (different function,
  no atom-leak concern)
- `safe_to_atom/1` in `Tau.CLI.Config` (uses `String.to_existing_atom/1` — no
  atom leak; correct pattern)
- `Init.provider_string/1` atom-to-string direction (inverse concern; no leak)
- Doctor-cmd per-provider bespoke resolution (different function, no
  Module.concat)

## Amendment log

- (none yet)
