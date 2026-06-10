---
template_version: 1
template_name: solution
parent_problem: ../../../problem.md
node_kind: leaf
synthesised_from: [proposals/proposal-2.md]
selection_method: single
revision: 0
---

# Solution: Static registry map replaces reflective tail clauses

## Recommendation

Replace the function-clause dispatch in `resolve_provider/1` and
`resolve_coding_agent/1` with module attributes (`@provider_registry` and
`@coding_agent_registry`) that define the complete allowed-string-to-module
mapping as `%{String.t() => module()}` compile-time maps. The `Module.concat` /
`String.capitalize` tail clauses are deleted. Unknown strings produce a tagged
error tuple `{:error, :unknown_provider | :unknown_coding_agent, String.t(),
[String.t()]}` where the fourth element is the map's key list, enabling
self-updating error messages. Callsites unwrap `{:ok, mod}` or handle the error
and `halt(1)`.

## Selected from

- **Chosen:** `proposals/proposal-2.md` (static registry map)
- **Why chosen:** Proposal 2 is the only candidate that simultaneously satisfies
  all three acceptance-criterion requirements in a single PR AND elevates the
  closed set to a first-class data structure. Proposal 1 (deletion) satisfies the
  AC with equal or less code but embeds the known set inside function-clause
  structure rather than a named, inspectable attribute — the set is not decomplected
  from the dispatch mechanism, only reorganised within it. Proposal 2's
  `@provider_registry` attribute is the single source of truth for both dispatch
  and error enumeration, removing the dual-representation risk that Proposal 4
  explicitly creates and accepts. Proposal 3 satisfies the AC at far higher
  migration cost (behaviour change across 10+ provider modules, `try/rescue`
  conflicting with OTP non-negotiable #7 in letter) for a benefit — open-set
  probing — that is out of scope and not required by the acceptance criterion.
  Proposal 4 fails the acceptance criterion outright: it defers `String.capitalize`
  removal to a follow-on PR and leaves duplicate known-name representations as a
  permanent coupling. On the comparison heuristics, Proposal 2 has Substantial
  decomplecting depth (the closed set becomes data); Proposal 1 has Surface depth
  (still function-clause shaped, just error-returning); Proposal 3 is Deep but
  costs High migration and Medium risk; Proposal 4 does not decomplect.

| # | Fit | Decomplecting depth | Migration cost | Risk | Reversibility |
|---|-----|---------------------|----------------|------|---------------|
| 1 | Yes | Surface | Low | Low | Easy |
| 2 | Yes | Substantial | Low | Low | Easy |
| 3 | Yes | Deep | High | Medium | Hard |
| 4 | Partially | None | Low | Low | Easy |

## What changes

- `lib/tau/cli.ex` — all changes are contained in this single file:
  - Add `@provider_registry %{String.t() => module()}` module attribute
    enumerating all known provider short-name → module mappings.
  - Add `@coding_agent_registry %{String.t() => module()}` module attribute
    enumerating all known coding-agent short-name → module mappings.
  - Replace all existing function clauses in `resolve_provider/1` with:
    a `nil` clause returning `{:ok, Tau.Provider.default()}`, a binary clause
    doing `Map.fetch(@provider_registry, name)`, and no tail clause.
  - Replace all existing function clauses in `resolve_coding_agent/1` with:
    a `nil` clause, an atom-passthrough clause, a binary clause doing
    `Map.fetch(@coding_agent_registry, name)`, and no tail clause.
  - Update each callsite of `resolve_provider/1` and `resolve_coding_agent/1`
    within `cli.ex` to unwrap `{:ok, mod}` or handle
    `{:error, :unknown_provider | :unknown_coding_agent, name, known_list}`
    with a `halt(1)` and a human-readable stderr message enumerating `known_list`.
  - Delete the comment at lines 807–811 that documented the `String.capitalize`
    limitation (the limitation is removed, not just documented away).

## What does not change

- `lib/tau/provider.ex` — the behaviour definition is unchanged; no new callback.
- All provider modules under `lib/tau/providers/` — no change required.
- All coding-agent modules under `lib/tau/coding_agents/` — no change required.
- `Tau.CLI.MCP.transport_for/1` — explicitly out of scope.
- `Tau.CLI.Config.safe_to_atom/1` — explicitly out of scope.
- `Init.provider_string/1` — explicitly out of scope.
- The existing `resolve_coding_agent/1` public API signature (the function
  remains `def`, not `defp`); only the return type changes.

## Migration sketch

Single PR touching only `lib/tau/cli.ex`. Sequence:

1. Add the two `@provider_registry` / `@coding_agent_registry` attributes.
2. Replace `resolve_provider/1` clauses; wrap existing `{:ok, mod}` returns;
   add error clause; delete tail clause.
3. Replace `resolve_coding_agent/1` clauses; same pattern.
4. Update the 1–3 internal callsites of `resolve_provider` in `cli.ex` to
   handle tagged returns.
5. Update `resolve_coding_agent` callers — check tests for external callers;
   update any that expect a bare module.
6. Verify `mix compile --warnings-as-errors` and `mix test`.

The PR is fully atomic: either both resolution functions are map-based with
error-returning types, or neither is. No partial-landing state.

## Open questions

- Are there external callers of `resolve_coding_agent/1` (it is `def`, not
  `defp`) in tests or other modules that expect a bare `module()` return and
  would need updating? A codebase-wide grep is required before implementation.
- The error tuple carries `[String.t()]` as the fourth element (the known keys).
  Callers must destructure this; if any caller only handles `{:error, reason}`
  two-tuples today, those callsites will need updating beyond the resolution
  functions. Check for defensive `{:error, _}` pattern matches.

## Linked sub-problems / proposals

- `proposals/proposal-1.md` — Delete tail clauses entirely, error-returning
  return type. Satisfies AC; Surface decomplecting depth; ultimately dominated
  by Proposal 2 on data-vs-code axis.
- `proposals/proposal-2.md` — Static registry map. **Selected.** Substantial
  decomplecting depth; same migration cost as Proposal 1; single source of truth.
- `proposals/proposal-3.md` — Behaviour-based self-registration with
  compile-time map derivation. Deep decomplecting but High migration cost,
  `try/rescue` OTP tension, API-breaking behaviour change.
- `proposals/proposal-4.md` — Validation façade at CLI boundary. Partially
  satisfies AC (defers `String.capitalize` removal; introduces dual
  representation). Not selected.

## Revision history

- (revision 0 — initial)
